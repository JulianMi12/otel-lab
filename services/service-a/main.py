"""
service-a - Microservicio orquestador (FastAPI).

Rol en la arquitectura:
    cliente -> [service-a] --HTTP--> [service-b]
                    |
                    +--SQL--> PostgreSQL

Es el punto de entrada del flujo de negocio. Recibe la peticion del cliente,
consulta PostgreSQL y enriquece la respuesta llamando a service-b. Esa llamada
HTTP es la que demuestra la propagacion de contexto W3C TraceContext: el header
`traceparent` viaja de A a B, por lo que ambos servicios aparecen bajo un UNICO
trace_id en Jaeger.

Instrumentacion:
    - Auto-instrumentacion: FastAPI (server spans), HTTPX (client spans +
      propagacion), psycopg2 (un span por query SQL).
    - Custom spans de negocio: order.process, fetch.order.db,
      call.service-b.inventory, order.compute_total.
"""

import asyncio
import os
import random
import time

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

from common.datastore import crear_almacen
from common.telemetry import (
    current_trace_id,
    instrument_fastapi,
    setup_telemetry,
    span_status_error,
)

# -----------------------------------------------------------------------------
# Configuracion
# -----------------------------------------------------------------------------
SERVICE_NAME = "service-a"
SERVICE_B_URL = os.getenv("SERVICE_B_URL", "http://service-b:8001")
DB_DSN = os.getenv("DATABASE_URL", "postgresql://app:secret@postgres:5432/appdb")
SERVICE_B_TIMEOUT = float(os.getenv("SERVICE_B_TIMEOUT", "5.0"))

# -----------------------------------------------------------------------------
# Telemetria: debe inicializarse ANTES de crear la app y el pool de conexiones,
# porque la auto-instrumentacion de psycopg2 parchea el driver al activarse.
# -----------------------------------------------------------------------------
tel = setup_telemetry(SERVICE_NAME, instrument_db=True)
log = tel.logger
tracer = tel.tracer
meter = tel.meter

# -----------------------------------------------------------------------------
# Instrumentos de metricas - los 4 SLIs del dashboard
# -----------------------------------------------------------------------------
# SLI-1 Disponibilidad y SLI-3 Error rate se derivan de este contador por status.
http_requests_total = meter.create_counter(
    "http_requests_total",
    description="Total de requests HTTP atendidos por service-a",
    unit="1",
)
# SLI-2 Latencia: el histograma permite calcular p50/p95/p99 en Prometheus.
http_request_duration = meter.create_histogram(
    "http_request_duration_seconds",
    description="Distribucion de latencia de requests HTTP",
    unit="s",
)
# SLI-4 Throughput se deriva por rate() sobre http_requests_total.
db_query_duration = meter.create_histogram(
    "db_query_duration_seconds",
    description="Latencia de las queries a PostgreSQL",
    unit="s",
)
service_b_calls_total = meter.create_counter(
    "service_b_calls_total",
    description="Llamadas HTTP salientes hacia service-b por resultado",
    unit="1",
)
active_requests = meter.create_up_down_counter(
    "http_active_requests",
    description="Requests en vuelo (senal de saturacion)",
    unit="1",
)
orders_processed_total = meter.create_counter(
    "orders_processed_total",
    description="Pedidos procesados por estado de negocio",
    unit="1",
)

# -----------------------------------------------------------------------------
# Acceso a datos
# -----------------------------------------------------------------------------
# El almacen se resuelve en el arranque: PostgreSQL si esta disponible, y en
# memoria si no. Eso permite desplegar en Cloud Run sin una base de datos
# gestionada, que es el unico recurso del stack con costo por hora continuo.
almacen = None


# -----------------------------------------------------------------------------
# Aplicacion
# -----------------------------------------------------------------------------
app = FastAPI(
    title="Service A - Orquestador",
    description="Microservicio de entrada del pipeline OTel end-to-end",
    version=os.getenv("APP_VERSION", "1.0.0"),
)


@app.on_event("startup")
async def on_startup():
    global almacen
    almacen = crear_almacen(log)
    log.info(
        "service-a listo",
        extra={"service_b_url": SERVICE_B_URL, "almacen": almacen.tipo},
    )


@app.on_event("shutdown")
async def on_shutdown():
    # Flush explicito: sin esto se pierden los spans y logs aun en el batch.
    if almacen:
        almacen.cerrar()
    tel.shutdown()


# Se instrumenta despues de declarar la app para envolver todas las rutas.
instrument_fastapi(app, tel)


@app.get("/health")
async def health():
    """Liveness probe. Excluido del pipeline de trazas (ruido sin valor)."""
    return {"status": "ok", "service": SERVICE_NAME}


@app.get("/")
async def root():
    return {
        "service": SERVICE_NAME,
        "otel_enabled": tel.enabled,
        "almacen": almacen.tipo if almacen else "no inicializado",
        "downstream": SERVICE_B_URL,
        "endpoints": ["/order/{id}", "/orders", "/fail", "/health", "/metrics"],
    }


@app.get("/orders")
async def list_orders():
    """Lista los IDs disponibles - util para alimentar el generador de carga."""
    ids = await asyncio.to_thread(almacen.listar_pedidos)
    return {"order_ids": ids, "count": len(ids)}


@app.get("/order/{order_id}")
async def get_order(order_id: str, request: Request):
    """
    Flujo de negocio principal, en tres pasos trazados:

        1. fetch.order.db          -> consulta el pedido en PostgreSQL
        2. call.service-b.inventory -> consulta inventario (propaga traceparent)
        3. order.compute_total      -> logica de negocio sobre ambos resultados

    El trace_id se devuelve en el body para que el benchmark y las capturas de
    evidencia puedan saltar directo a la traza exacta en Jaeger.
    """
    start = time.perf_counter()
    base_labels = {"endpoint": "/order", "method": "GET", "service": SERVICE_NAME}
    active_requests.add(1, base_labels)
    status_code = 200

    try:
        # -- Span raiz de negocio: agrupa los tres pasos bajo una operacion -----
        with tracer.start_as_current_span(
            "order.process",
            attributes={"order.id": order_id, "business.operation": "get_order"},
        ) as root_span:

            # -- Paso 1: lectura en base de datos -----------------------------
            with tracer.start_as_current_span(
                "fetch.order.db",
                attributes={
                    "db.system": almacen.db_system,
                    "db.operation": "SELECT",
                    "db.name": "appdb",
                    "order.id": order_id,
                },
            ) as db_span:
                db_start = time.perf_counter()
                try:
                    row = await asyncio.to_thread(almacen.obtener_pedido, order_id)
                except Exception as exc:
                    span_status_error(db_span, exc)
                    log.error(
                        "Fallo la consulta a PostgreSQL",
                        extra={"order_id": order_id, "error": str(exc)},
                    )
                    status_code = 500
                    raise HTTPException(status_code=500, detail="Database error")
                finally:
                    db_query_duration.record(
                        time.perf_counter() - db_start,
                        {"operation": "SELECT", "table": "orders"},
                    )

                if not row:
                    db_span.set_attribute("order.found", False)
                    log.warning("Pedido inexistente", extra={"order_id": order_id})
                    orders_processed_total.add(1, {"result": "not_found"})
                    status_code = 404
                    raise HTTPException(
                        status_code=404, detail="Order " + order_id + " not found"
                    )

                order = {
                    "id": row[0],
                    "product": row[1],
                    "quantity": row[2],
                    "status": row[3],
                    "unit_price": float(row[4]),
                }
                db_span.set_attribute("order.found", True)
                db_span.set_attribute("order.status", order["status"])
                log.info(
                    "Pedido recuperado de la base de datos",
                    extra={"order_id": order_id, "status": order["status"]},
                )

            # -- Paso 2: llamada downstream con propagacion de contexto -------
            inventory = await _call_service_b(order["product"])

            # -- Paso 3: logica de negocio ------------------------------------
            with tracer.start_as_current_span("order.compute_total") as calc_span:
                total = order["unit_price"] * order["quantity"]
                fulfillable = inventory.get("available", 0) >= order["quantity"]
                calc_span.set_attribute("order.total_amount", total)
                calc_span.set_attribute("order.fulfillable", fulfillable)

            root_span.set_attribute("order.fulfillable", fulfillable)
            orders_processed_total.add(
                1, {"result": "fulfillable" if fulfillable else "backorder"}
            )

            trace_id = current_trace_id()
            log.info(
                "Pedido procesado",
                extra={
                    "order_id": order_id,
                    "total": total,
                    "fulfillable": fulfillable,
                },
            )

            return {
                "order": order,
                "inventory": inventory,
                "total_amount": round(total, 2),
                "fulfillable": fulfillable,
                "trace_id": trace_id,
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
        # Un unico punto de registro por request: evita el doble conteo que
        # se produce al incrementar el contador en varias ramas del flujo.
        http_requests_total.add(
            1, dict(base_labels, status=status_class, status_code=str(status_code))
        )
        http_request_duration.record(elapsed, dict(base_labels, status=status_class))
        active_requests.add(-1, base_labels)


async def _call_service_b(product):
    """
    Llama a service-b. HTTPXClientInstrumentor inyecta automaticamente el header
    `traceparent` (formato W3C: 00-<trace_id>-<span_id>-<flags>), por lo que
    service-b continua la MISMA traza en vez de iniciar una nueva.
    """
    with tracer.start_as_current_span(
        "call.service-b.inventory",
        attributes={
            "peer.service": "service-b",
            "http.method": "GET",
            "order.product": product,
        },
    ) as span:
        service_b_calls_total.add(1, {"result": "attempt"})
        try:
            async with httpx.AsyncClient(timeout=SERVICE_B_TIMEOUT) as client:
                resp = await client.get(SERVICE_B_URL + "/inventory/" + product)
                resp.raise_for_status()
                inventory = resp.json()

            service_b_calls_total.add(1, {"result": "success"})
            span.set_attribute("http.status_code", resp.status_code)
            span.set_attribute("inventory.available", inventory.get("available", 0))
            log.info(
                "Inventario obtenido de service-b",
                extra={"product": product, "available": inventory.get("available")},
            )
            return inventory

        except httpx.HTTPStatusError as exc:
            # El codigo vive en exc.response.status_code; httpx.HTTPStatusError
            # no expone un atributo .status_code propio.
            code = exc.response.status_code
            service_b_calls_total.add(1, {"result": "http_error"})
            span_status_error(span, exc)
            span.set_attribute("http.status_code", code)
            log.error(
                "service-b respondio con error",
                extra={"product": product, "status_code": code},
            )
            return {"available": -1, "error": "service-b status " + str(code)}

        except httpx.RequestError as exc:
            # Fallo de red o timeout: el servicio degrada en vez de caerse.
            service_b_calls_total.add(1, {"result": "unavailable"})
            span_status_error(span, exc)
            log.error(
                "service-b inalcanzable",
                extra={"product": product, "error": str(exc)},
            )
            return {"available": -1, "error": "service-b unavailable"}


@app.get("/fail")
async def simulate_failure():
    """
    Genera errores de forma deliberada (~50%) para poblar el panel de error rate
    y producir trazas con status ERROR visibles en Jaeger.
    """
    labels = {"endpoint": "/fail", "method": "GET", "service": SERVICE_NAME}
    with tracer.start_as_current_span("simulate.failure") as span:
        if random.random() < 0.5:
            exc = RuntimeError("Fallo sintetico inyectado para la demo")
            span_status_error(span, exc)
            log.error("Fallo sintetico", extra={"endpoint": "/fail"})
            http_requests_total.add(1, dict(labels, status="5xx", status_code="500"))
            return JSONResponse(
                status_code=500,
                content={"error": str(exc), "trace_id": current_trace_id()},
            )
        http_requests_total.add(1, dict(labels, status="2xx", status_code="200"))
        return {"status": "ok", "trace_id": current_trace_id()}
