"""
service-b - Microservicio de inventario (FastAPI).

Rol en la arquitectura:
    [service-a] --HTTP--> [service-b] --SQL--> PostgreSQL

Es el servicio downstream. No inicia trazas propias cuando lo invoca service-a:
la auto-instrumentacion de FastAPI lee el header `traceparent` entrante y
CONTINUA la traza existente, creando spans hijos bajo el mismo trace_id. Esa es
la prueba de que la propagacion de contexto W3C funciona extremo a extremo.

Instrumentacion:
    - Auto-instrumentacion: FastAPI (extrae traceparent), psycopg2 (spans SQL).
    - Custom spans de negocio: inventory.lookup.db, inventory.validate.stock,
      inventory.reserve.
"""

import asyncio
import os
import random
import time

from fastapi import FastAPI, HTTPException
from psycopg2.pool import ThreadedConnectionPool

from common.telemetry import (
    current_trace_id,
    instrument_fastapi,
    setup_telemetry,
    span_status_error,
)

# -----------------------------------------------------------------------------
# Configuracion
# -----------------------------------------------------------------------------
SERVICE_NAME = "service-b"
DB_DSN = os.getenv("DATABASE_URL", "postgresql://app:secret@postgres:5432/appdb")
# Latencia artificial opcional: permite demostrar percentiles p95/p99 realistas
# en el dashboard sin necesidad de una carga enorme.
LATENCY_JITTER_MS = int(os.getenv("LATENCY_JITTER_MS", "0"))

tel = setup_telemetry(SERVICE_NAME, instrument_db=True)
log = tel.logger
tracer = tel.tracer
meter = tel.meter

# -----------------------------------------------------------------------------
# Instrumentos de metricas
# -----------------------------------------------------------------------------
http_requests_total = meter.create_counter(
    "http_requests_total",
    description="Total de requests HTTP atendidos por service-b",
    unit="1",
)
http_request_duration = meter.create_histogram(
    "http_request_duration_seconds",
    description="Distribucion de latencia de requests HTTP",
    unit="s",
)
db_query_duration = meter.create_histogram(
    "db_query_duration_seconds",
    description="Latencia de las queries a PostgreSQL",
    unit="s",
)
inventory_lookups_total = meter.create_counter(
    "inventory_lookups_total",
    description="Consultas de inventario por resultado de negocio",
    unit="1",
)
active_requests = meter.create_up_down_counter(
    "http_active_requests",
    description="Requests en vuelo (senal de saturacion)",
    unit="1",
)

db_pool = None


def init_db_pool(retries=10, delay=2.0):
    global db_pool
    for attempt in range(1, retries + 1):
        try:
            db_pool = ThreadedConnectionPool(minconn=2, maxconn=20, dsn=DB_DSN)
            log.info("Pool de PostgreSQL inicializado", extra={"intento": attempt})
            return
        except Exception as exc:
            log.warning(
                "PostgreSQL no disponible, reintentando",
                extra={"intento": attempt, "error": str(exc)},
            )
            time.sleep(delay)
    raise RuntimeError("No se pudo conectar a PostgreSQL tras varios intentos")


def query_inventory(product_id):
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT product, available, reserved, warehouse "
                "FROM inventory WHERE product = %s",
                (product_id,),
            )
            return cur.fetchone()
    finally:
        db_pool.putconn(conn)


def reserve_inventory(product_id, quantity):
    """
    Reserva stock de forma atomica. La clausula WHERE available >= quantity
    evita sobreventa bajo concurrencia sin bloquear la tabla.
    """
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE inventory SET available = available - %s, "
                "reserved = reserved + %s "
                "WHERE product = %s AND available >= %s "
                "RETURNING available, reserved",
                (quantity, quantity, product_id, quantity),
            )
            result = cur.fetchone()
        conn.commit()
        return result
    except Exception:
        conn.rollback()
        raise
    finally:
        db_pool.putconn(conn)


app = FastAPI(
    title="Service B - Inventario",
    description="Microservicio downstream del pipeline OTel end-to-end",
    version=os.getenv("APP_VERSION", "1.0.0"),
)


@app.on_event("startup")
async def on_startup():
    init_db_pool()
    log.info("service-b listo", extra={"latency_jitter_ms": LATENCY_JITTER_MS})


@app.on_event("shutdown")
async def on_shutdown():
    if db_pool:
        db_pool.closeall()
    tel.shutdown()


instrument_fastapi(app, tel)


@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE_NAME}


@app.get("/")
async def root():
    return {
        "service": SERVICE_NAME,
        "otel_enabled": tel.enabled,
        "endpoints": ["/inventory/{product}", "/inventory/{product}/reserve", "/health"],
    }


@app.get("/inventory/{product_id}")
async def get_inventory(product_id: str):
    """
    Consulta de inventario invocada por service-a.

    Los spans creados aqui cuelgan del span cliente de service-a porque FastAPI
    extrajo el `traceparent` entrante: en Jaeger se ve un solo arbol con ambos
    servicios, no dos trazas separadas.
    """
    start = time.perf_counter()
    base_labels = {"endpoint": "/inventory", "method": "GET", "service": SERVICE_NAME}
    active_requests.add(1, base_labels)
    status_code = 200

    try:
        # -- Paso 1: lectura del stock en base de datos ----------------------
        with tracer.start_as_current_span(
            "inventory.lookup.db",
            attributes={
                "db.system": "postgresql",
                "db.operation": "SELECT",
                "db.name": "appdb",
                "product.id": product_id,
            },
        ) as db_span:
            db_start = time.perf_counter()
            try:
                row = await asyncio.to_thread(query_inventory, product_id)
            except Exception as exc:
                span_status_error(db_span, exc)
                log.error(
                    "Fallo la consulta de inventario",
                    extra={"product": product_id, "error": str(exc)},
                )
                status_code = 500
                raise HTTPException(status_code=500, detail="Database error")
            finally:
                db_query_duration.record(
                    time.perf_counter() - db_start,
                    {"operation": "SELECT", "table": "inventory"},
                )

            if not row:
                db_span.set_attribute("product.found", False)
                inventory_lookups_total.add(1, {"result": "not_found"})
                log.warning("Producto sin registro de inventario",
                            extra={"product": product_id})
                status_code = 404
                raise HTTPException(
                    status_code=404, detail="Product " + product_id + " not found"
                )

            product, available, reserved, warehouse = row
            db_span.set_attribute("product.found", True)
            db_span.set_attribute("inventory.available", available)

        # -- Paso 2: regla de negocio sobre el stock -------------------------
        with tracer.start_as_current_span("inventory.validate.stock") as val_span:
            # Jitter opcional: simula la variabilidad de un sistema real para
            # que los percentiles del dashboard no sean una linea plana.
            if LATENCY_JITTER_MS > 0:
                await asyncio.sleep(random.uniform(0, LATENCY_JITTER_MS) / 1000.0)

            if available <= 0:
                stock_level = "out_of_stock"
            elif available < 10:
                stock_level = "low"
            else:
                stock_level = "healthy"

            val_span.set_attribute("inventory.stock_level", stock_level)
            val_span.set_attribute("inventory.reserved", reserved)
            inventory_lookups_total.add(1, {"result": stock_level})

        log.info(
            "Inventario consultado",
            extra={
                "product": product_id,
                "available": available,
                "stock_level": stock_level,
            },
        )

        return {
            "product": product,
            "available": available,
            "reserved": reserved,
            "warehouse": warehouse,
            "stock_level": stock_level,
            "trace_id": current_trace_id(),
        }

    except HTTPException as exc:
        status_code = exc.status_code
        raise
    except Exception:
        status_code = 500
        raise
    finally:
        elapsed = time.perf_counter() - start
        status_class = str(status_code)[0] + "xx"
        http_requests_total.add(
            1, dict(base_labels, status=status_class, status_code=str(status_code))
        )
        http_request_duration.record(elapsed, dict(base_labels, status=status_class))
        active_requests.add(-1, base_labels)


@app.post("/inventory/{product_id}/reserve")
async def reserve(product_id: str, quantity: int = 1):
    """Reserva stock. Escritura trazada que demuestra spans de mutacion en DB."""
    base_labels = {"endpoint": "/reserve", "method": "POST", "service": SERVICE_NAME}
    start = time.perf_counter()
    status_code = 200

    try:
        with tracer.start_as_current_span(
            "inventory.reserve",
            attributes={
                "db.system": "postgresql",
                "db.operation": "UPDATE",
                "product.id": product_id,
                "reserve.quantity": quantity,
            },
        ) as span:
            try:
                result = await asyncio.to_thread(
                    reserve_inventory, product_id, quantity
                )
            except Exception as exc:
                span_status_error(span, exc)
                log.error(
                    "Fallo la reserva de inventario",
                    extra={"product": product_id, "error": str(exc)},
                )
                status_code = 500
                raise HTTPException(status_code=500, detail="Reserve failed")

            if not result:
                # Sin filas afectadas: no habia stock suficiente.
                span.set_attribute("reserve.success", False)
                log.warning(
                    "Stock insuficiente para reservar",
                    extra={"product": product_id, "quantity": quantity},
                )
                status_code = 409
                raise HTTPException(status_code=409, detail="Insufficient stock")

            available, reserved = result
            span.set_attribute("reserve.success", True)
            span.set_attribute("inventory.available", available)
            log.info(
                "Stock reservado",
                extra={
                    "product": product_id,
                    "quantity": quantity,
                    "available": available,
                },
            )

            return {
                "product": product_id,
                "reserved_now": quantity,
                "available": available,
                "reserved_total": reserved,
                "trace_id": current_trace_id(),
            }

    except HTTPException as exc:
        status_code = exc.status_code
        raise
    except Exception:
        status_code = 500
        raise
    finally:
        status_class = str(status_code)[0] + "xx"
        http_requests_total.add(
            1, dict(base_labels, status=status_class, status_code=str(status_code))
        )
        http_request_duration.record(
            time.perf_counter() - start, dict(base_labels, status=status_class)
        )
