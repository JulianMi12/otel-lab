"""
data-service - Microservicio de analitica (FastAPI).

Rol en la arquitectura:

    cliente ──▶ service-a ──┬──▶ service-b      (inventario)
                            └──▶ data-service   (analitica)
                                      │
                                      └──SQL──▶ PostgreSQL / Cloud SQL / RDS

Es el tercer microservicio del laboratorio integrador. A diferencia de
service-b, que hace lecturas puntuales, este ejecuta consultas de agregacion:
cuenta pedidos, suma importes y calcula el ticket medio de un producto.

Lo que aporta al conjunto:

  - Una traza con TRES servicios bajo un unico trace_id, en lugar de dos.
  - Spans de base de datos anotados con las DB Semantic Conventions de
    OpenTelemetry (db.system, db.operation, db.name, db.statement,
    db.collection.name), que es lo que pide el Modulo A.
  - Un punto de inyeccion de fallos para el Modulo D: CHAOS_ERROR_RATE
    permite reproducir el experimento de "error rate 10 % en data-service".
"""

import asyncio
import os
import random
import time

from fastapi import FastAPI, HTTPException
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
SERVICE_NAME = "data-service"
DB_NAME = os.getenv("DB_NAME", "appdb")

# -- Inyeccion de fallos para el Modulo D -------------------------------------
# Estas variables permiten reproducir los experimentos de caos desde dentro de
# la aplicacion. Es el camino menos recomendable -el fallo deberia inyectarse
# por fuera, con Toxiproxy en local o Chaos Mesh en Kubernetes, para que el
# servicio no sepa que esta siendo atacado- pero el enunciado pide
# explicitamente "error rate 10 % en data-service", y tenerlo aqui permite
# ejecutar el experimento tambien en entornos donde no se puede interponer un
# proxy, como Cloud Run.
#
# En condiciones normales ambas valen 0 y el codigo de caos no se ejecuta.
CHAOS_LATENCY_MS = int(os.getenv("CHAOS_LATENCY_MS", "0"))
CHAOS_ERROR_RATE = float(os.getenv("CHAOS_ERROR_RATE", "0"))

tel = setup_telemetry(SERVICE_NAME, instrument_db=True)
log = tel.logger
tracer = tel.tracer
meter = tel.meter

# -----------------------------------------------------------------------------
# Instrumentos de metricas
# -----------------------------------------------------------------------------
# El texto de `description` acaba como el HELP de Prometheus, y en
# Prometheus el nombre de la metrica es GLOBAL: si dos servicios publican
# `http_requests_total` con HELP distinto, la libreria cliente rechaza la
# coleccion ENTERA con "has help X but should have Y" y el endpoint deja de
# servir metricas. Se detecto exactamente eso en el laboratorio: la serie de
# error_rate aparecia con huecos sin causa aparente.
#
# Por eso las descripciones de las metricas compartidas son IDENTICAS en los
# tres servicios y no mencionan a ninguno: quien emite cada punto se sabe por
# la etiqueta `service`, no por el texto de ayuda.
http_requests_total = meter.create_counter(
    "http_requests_total",
    description="Total de requests HTTP atendidos",
    unit="1",
)
http_request_duration = meter.create_histogram(
    "http_request_duration_seconds",
    description="Distribucion de latencia de requests HTTP",
    unit="s",
)
db_query_duration = meter.create_histogram(
    "db_query_duration_seconds",
    description="Latencia de las consultas a la base de datos",
    unit="s",
)
db_errors_total = meter.create_counter(
    "db_errors_total",
    description="Errores en consultas a la base de datos",
    unit="1",
)
data_requests_total = meter.create_counter(
    "data_requests_total",
    description="Consultas analiticas por resultado de negocio",
    unit="1",
)
chaos_faults_total = meter.create_counter(
    "chaos_faults_total",
    description="Fallos inyectados deliberadamente por el modo caos",
    unit="1",
)
active_requests = meter.create_up_down_counter(
    "http_active_requests",
    description="Requests en vuelo (senal de saturacion)",
    unit="1",
)

almacen = None


# -----------------------------------------------------------------------------
# Inyeccion de fallos
# -----------------------------------------------------------------------------
async def aplicar_caos(span):
    """
    Aplica la latencia o el error configurados, si los hay.

    Marca el span con `chaos.injected` para que al analizar una traza quede
    claro que la degradacion fue deliberada y no un fallo real del sistema.
    Sin esa marca, un experimento de caos y una incidencia autentica son
    indistinguibles en la traza.
    """
    if CHAOS_LATENCY_MS > 0:
        span.set_attribute("chaos.injected", True)
        span.set_attribute("chaos.type", "latency")
        span.set_attribute("chaos.latency_ms", CHAOS_LATENCY_MS)
        chaos_faults_total.add(1, {"type": "latency"})
        log.warning(
            "Caos: latencia inyectada",
            extra={"latency_ms": CHAOS_LATENCY_MS},
        )
        await asyncio.sleep(CHAOS_LATENCY_MS / 1000.0)

    if CHAOS_ERROR_RATE > 0 and random.random() < CHAOS_ERROR_RATE:
        span.set_attribute("chaos.injected", True)
        span.set_attribute("chaos.type", "error")
        span.set_attribute("chaos.error_rate", CHAOS_ERROR_RATE)
        chaos_faults_total.add(1, {"type": "error"})
        log.error(
            "Caos: error inyectado",
            extra={"error_rate": CHAOS_ERROR_RATE},
        )
        return True

    return False


# -----------------------------------------------------------------------------
# Aplicacion
# -----------------------------------------------------------------------------
app = FastAPI(
    title="Data Service - Analitica",
    description="Tercer microservicio del pipeline: consultas de agregacion",
    version=os.getenv("APP_VERSION", "1.0.0"),
)


@app.on_event("startup")
async def on_startup():
    global almacen
    almacen = crear_almacen(log)
    log.info(
        "data-service listo",
        extra={
            "almacen": almacen.tipo,
            "chaos_latency_ms": CHAOS_LATENCY_MS,
            "chaos_error_rate": CHAOS_ERROR_RATE,
        },
    )


@app.on_event("shutdown")
async def on_shutdown():
    if almacen:
        almacen.cerrar()
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
        "almacen": almacen.tipo if almacen else "no inicializado",
        "endpoints": ["/data/products", "/data/analytics/{product}", "/chaos/status"],
    }


@app.get("/chaos/status")
async def chaos_status():
    """
    Expone si hay caos activo. Lo consultan los scripts de experimento para
    confirmar que el fallo se aplico antes de empezar a medir.
    """
    return {
        "chaos_latency_ms": CHAOS_LATENCY_MS,
        "chaos_error_rate": CHAOS_ERROR_RATE,
        "chaos_active": CHAOS_LATENCY_MS > 0 or CHAOS_ERROR_RATE > 0,
    }


@app.get("/data/products")
async def listar_productos(limite: int = 50):
    """Catalogo de productos con su stock agregado."""
    inicio = time.perf_counter()
    etiquetas = {"endpoint": "/data/products", "method": "GET", "service": SERVICE_NAME}
    active_requests.add(1, etiquetas)
    codigo = 200

    try:
        with tracer.start_as_current_span(
            "data.products.query",
            attributes={
                # DB Semantic Conventions de OpenTelemetry
                "db.system": almacen.db_system,
                "db.name": DB_NAME,
                "db.operation": "SELECT",
                "db.collection.name": "inventory",
                "db.statement": (
                    "SELECT product, available, reserved, warehouse "
                    "FROM inventory ORDER BY product LIMIT ?"
                ),
            },
        ) as span:
            inicio_db = time.perf_counter()
            try:
                filas = await asyncio.to_thread(almacen.listar_productos, limite)
            except Exception as exc:
                span_status_error(span, exc)
                db_errors_total.add(1, {"operation": "SELECT", "table": "inventory"})
                log.error("Fallo la consulta de productos", extra={"error": str(exc)})
                codigo = 500
                raise HTTPException(status_code=500, detail="Database error")
            finally:
                db_query_duration.record(
                    time.perf_counter() - inicio_db,
                    {"operation": "SELECT", "table": "inventory"},
                )

            span.set_attribute("db.rows_affected", len(filas))

        productos = [
            {
                "product": f[0],
                "available": f[1],
                "reserved": f[2],
                "warehouse": f[3],
            }
            for f in filas
        ]
        data_requests_total.add(1, {"query": "products", "result": "ok"})

        return {
            "products": productos,
            "count": len(productos),
            "trace_id": current_trace_id(),
        }

    except HTTPException as exc:
        codigo = exc.status_code
        raise
    except Exception:
        codigo = 500
        raise
    finally:
        _registrar(etiquetas, codigo, inicio)


@app.get("/data/analytics/{product_id}")
async def analitica_producto(product_id: str):
    """
    Agregacion sobre los pedidos de un producto: numero de pedidos, unidades,
    importe total, ticket medio y pedidos entregados.

    El span lleva el texto de la consulta en `db.statement` con el parametro
    como marcador, nunca interpolado: asi el atributo no transporta datos del
    usuario a la traza.
    """
    inicio = time.perf_counter()
    etiquetas = {
        "endpoint": "/data/analytics",
        "method": "GET",
        "service": SERVICE_NAME,
    }
    active_requests.add(1, etiquetas)
    codigo = 200

    try:
        with tracer.start_as_current_span(
            "data.analytics.aggregate",
            attributes={
                "db.system": almacen.db_system,
                "db.name": DB_NAME,
                "db.operation": "SELECT",
                "db.collection.name": "orders",
                "db.statement": almacen.SQL_ANALITICA,
                "product.id": product_id,
                "analytics.type": "aggregation",
            },
        ) as span:

            # El caos se aplica dentro del span para que la degradacion quede
            # registrada en la traza junto a la operacion afectada.
            if await aplicar_caos(span):
                exc = RuntimeError("Fallo inyectado por el experimento de caos")
                span_status_error(span, exc)
                codigo = 503
                data_requests_total.add(1, {"query": "analytics", "result": "chaos"})
                return JSONResponse(
                    status_code=503,
                    content={
                        "error": "Servicio degradado por experimento de caos",
                        "chaos": True,
                        "trace_id": current_trace_id(),
                    },
                )

            inicio_db = time.perf_counter()
            try:
                fila = await asyncio.to_thread(
                    almacen.analitica_producto, product_id
                )
            except Exception as exc:
                span_status_error(span, exc)
                db_errors_total.add(1, {"operation": "SELECT", "table": "orders"})
                log.error(
                    "Fallo la consulta analitica",
                    extra={"product": product_id, "error": str(exc)},
                )
                codigo = 500
                raise HTTPException(status_code=500, detail="Database error")
            finally:
                db_query_duration.record(
                    time.perf_counter() - inicio_db,
                    {"operation": "SELECT", "table": "orders"},
                )

            if not fila:
                span.set_attribute("db.rows_affected", 0)
                data_requests_total.add(1, {"query": "analytics", "result": "not_found"})
                log.warning("Producto sin pedidos", extra={"product": product_id})
                codigo = 404
                raise HTTPException(
                    status_code=404,
                    detail="Sin datos de ventas para " + product_id,
                )

            span.set_attribute("db.rows_affected", 1)
            span.set_attribute("analytics.orders", fila[1])
            span.set_attribute("analytics.revenue", fila[3])

        resultado = {
            "product": fila[0],
            "orders": fila[1],
            "units_sold": fila[2],
            "revenue": fila[3],
            "avg_ticket": fila[4],
            "delivered": fila[5],
            "trace_id": current_trace_id(),
        }

        data_requests_total.add(1, {"query": "analytics", "result": "ok"})
        log.info(
            "Analitica calculada",
            extra={
                "product": product_id,
                "orders": fila[1],
                "revenue": fila[3],
            },
        )
        return resultado

    except HTTPException as exc:
        codigo = exc.status_code
        raise
    except Exception:
        codigo = 500
        raise
    finally:
        _registrar(etiquetas, codigo, inicio)


def _registrar(etiquetas, codigo, inicio):
    """Punto unico de registro por peticion, para no contar dos veces."""
    clase = str(codigo)[0] + "xx"
    http_requests_total.add(
        1, dict(etiquetas, status=clase, status_code=str(codigo))
    )
    http_request_duration.record(
        time.perf_counter() - inicio, dict(etiquetas, status=clase)
    )
    active_requests.add(-1, etiquetas)
