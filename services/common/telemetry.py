"""
telemetry.py - Bootstrap unificado de OpenTelemetry para los microservicios del lab.

Centraliza los TRES PILARES de observabilidad en un solo punto:

    1. TRAZAS   -> TracerProvider  -> OTLP/gRPC -> OTel Collector
    2. METRICAS -> MeterProvider   -> (a) OTLP/gRPC push al Collector
                                      (b) PrometheusMetricReader -> /metrics scrapeable
    3. LOGS     -> LoggerProvider  -> OTLP/gRPC -> Collector -> Loki
                                      + stdout JSON con trace_id/span_id inyectado

La variable de entorno OTEL_ENABLED permite desactivar POR COMPLETO la
instrumentacion sin tocar el codigo de negocio. Esto es lo que hace posible el
benchmark comparativo de overhead (linea base vs. instrumentado) ejecutando
exactamente la misma imagen y el mismo codigo de aplicacion.
"""

import logging
import os
import sys

from pythonjsonlogger import jsonlogger

# -----------------------------------------------------------------------------
# Configuracion por entorno
# -----------------------------------------------------------------------------
OTEL_ENABLED = os.getenv("OTEL_ENABLED", "true").lower() in ("1", "true", "yes")
OTEL_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
PROMETHEUS_PORT = int(os.getenv("PROMETHEUS_PORT", "9464"))
ENV = os.getenv("ENVIRONMENT", "development")
APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
CLOUD_PROVIDER = os.getenv("CLOUD_PROVIDER", "local")

# Intervalo de export de metricas: 15s alinea con el scrape_interval de Prometheus.
METRIC_EXPORT_INTERVAL_MS = int(os.getenv("OTEL_METRIC_EXPORT_INTERVAL", "15000"))


# -----------------------------------------------------------------------------
# Logging estructurado JSON - el puente de correlacion log <-> traza
# -----------------------------------------------------------------------------
class OtelJsonFormatter(jsonlogger.JsonFormatter):
    """
    Formatter JSON que inyecta trace_id y span_id del span activo en cada log.

    El trace_id en formato hexadecimal de 32 digitos (W3C TraceContext) es el
    PIVOTE que permite saltar de una linea de log a la traza completa en Grafana
    y viceversa. Sin este campo no existe correlacion cross-signal.
    """

    def __init__(self, *args, service_name="unknown", **kwargs):
        super().__init__(*args, **kwargs)
        self.service_name = service_name

    def add_fields(self, log_record, record, message_dict):
        super().add_fields(log_record, record, message_dict)

        if OTEL_ENABLED:
            from opentelemetry import trace

            span = trace.get_current_span()
            ctx = span.get_span_context()
            if ctx and ctx.is_valid:
                # 032x / 016x = representacion hexadecimal canonica del estandar W3C
                log_record["trace_id"] = format(ctx.trace_id, "032x")
                log_record["span_id"] = format(ctx.span_id, "016x")
                log_record["trace_flags"] = format(ctx.trace_flags, "02x")

        log_record["service"] = self.service_name
        log_record["version"] = APP_VERSION
        log_record["environment"] = ENV
        log_record["otel_enabled"] = OTEL_ENABLED

        # 'level' en minuscula facilita las queries LogQL en Loki
        if "levelname" in log_record:
            log_record["level"] = log_record.pop("levelname").lower()


def _setup_stdout_logging(service_name):
    """Configura el root logger para emitir JSON de una linea a stdout."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        OtelJsonFormatter(
            "%(asctime)s %(levelname)s %(name)s %(message)s",
            service_name=service_name,
        )
    )

    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(logging.INFO)

    # uvicorn trae sus propios handlers: se neutralizan para que todo el log del
    # proceso salga en el mismo formato JSON correlacionado.
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        lg = logging.getLogger(name)
        lg.handlers.clear()
        lg.propagate = True

    return logging.getLogger(service_name)


# -----------------------------------------------------------------------------
# Objeto devuelto al servicio
# -----------------------------------------------------------------------------
class Telemetry:
    """Agrupa los handles de telemetria que consume el codigo de negocio."""

    def __init__(self, service_name):
        self.service_name = service_name
        self.logger = _setup_stdout_logging(service_name)
        self.tracer = None
        self.meter = None
        self._providers = []
        self.enabled = OTEL_ENABLED

    def shutdown(self):
        """Flush de las senales pendientes antes de terminar el proceso."""
        for provider in self._providers:
            try:
                provider.shutdown()
            except Exception as exc:  # el shutdown nunca debe tumbar el servicio
                self.logger.warning("Fallo al cerrar provider: %s", exc)


class _NoopSpan:
    """Span inerte usado cuando OTEL_ENABLED=false (modo linea base)."""

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def set_attribute(self, *args, **kwargs):
        pass

    def set_status(self, *args, **kwargs):
        pass

    def record_exception(self, *args, **kwargs):
        pass

    def add_event(self, *args, **kwargs):
        pass


class _NoopTracer:
    def start_as_current_span(self, *args, **kwargs):
        return _NoopSpan()


class _NoopInstrument:
    def add(self, *args, **kwargs):
        pass

    def record(self, *args, **kwargs):
        pass


class _NoopMeter:
    def create_counter(self, *args, **kwargs):
        return _NoopInstrument()

    def create_histogram(self, *args, **kwargs):
        return _NoopInstrument()

    def create_up_down_counter(self, *args, **kwargs):
        return _NoopInstrument()


# -----------------------------------------------------------------------------
# Vistas de agregacion: fronteras explicitas de los histogramas
# -----------------------------------------------------------------------------
# Los buckets por defecto del SDK de OpenTelemetry son
# [0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000],
# pensados para valores en MILISEGUNDOS. Este laboratorio registra la latencia
# en SEGUNDOS (la convencion de Prometheus), asi que practicamente todas las
# muestras caerian en el primer bucket [0, 5) y histogram_quantile interpolaria
# el p99 cerca de 5 s sin importar la latencia real.
#
# Estas fronteras son las estandar del cliente de Prometheus para latencia HTTP,
# y hacen que los percentiles del dashboard y del benchmark sean fiables.
LIMITES_LATENCIA_HTTP = [
    0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75,
    1.0, 2.5, 5.0, 7.5, 10.0,
]

# Las queries a la base de datos son un orden de magnitud mas rapidas que un
# request HTTP completo, por lo que necesitan fronteras mas finas en el extremo
# bajo para no colapsar todas las muestras en un unico bucket.
LIMITES_LATENCIA_DB = [
    0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.075,
    0.1, 0.25, 0.5, 1.0, 2.5,
]


def _vistas_histogramas():
    """Vistas que sustituyen los buckets por defecto en los histogramas."""
    from opentelemetry.sdk.metrics import Histogram
    from opentelemetry.sdk.metrics.view import (
        ExplicitBucketHistogramAggregation,
        View,
    )

    return [
        View(
            instrument_type=Histogram,
            instrument_name="http_request_duration_seconds",
            aggregation=ExplicitBucketHistogramAggregation(
                boundaries=LIMITES_LATENCIA_HTTP
            ),
        ),
        View(
            instrument_type=Histogram,
            instrument_name="db_query_duration_seconds",
            aggregation=ExplicitBucketHistogramAggregation(
                boundaries=LIMITES_LATENCIA_DB
            ),
        ),
    ]


# -----------------------------------------------------------------------------
# Bootstrap principal
# -----------------------------------------------------------------------------
def setup_telemetry(service_name, instrument_db=True):
    """
    Inicializa los tres pilares y devuelve los handles para el codigo de negocio.

    Con OTEL_ENABLED=false devuelve implementaciones no-op: el servicio funciona
    identicamente pero sin ningun costo de instrumentacion. Esa es la linea base
    del benchmark de overhead.
    """
    tel = Telemetry(service_name)

    if not OTEL_ENABLED:
        tel.tracer = _NoopTracer()
        tel.meter = _NoopMeter()
        tel.logger.info(
            "Telemetria DESACTIVADA (OTEL_ENABLED=false) - modo linea base de benchmark"
        )
        return tel

    # Imports diferidos: en modo linea base el SDK ni siquiera se carga en memoria.
    from opentelemetry import metrics, trace
    from opentelemetry._logs import set_logger_provider
    from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
    from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.exporter.prometheus import PrometheusMetricReader
    from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
    from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
    from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.sdk.resources import SERVICE_NAME, SERVICE_VERSION, Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from prometheus_client import start_http_server

    # -- 1. Resource: identidad comun a las TRES senales ----------------------
    # El mismo Resource en trazas, metricas y logs es lo que permite filtrar y
    # cruzar las tres por service.name en Grafana.
    resource = Resource.create(
        {
            SERVICE_NAME: service_name,
            SERVICE_VERSION: APP_VERSION,
            "deployment.environment": ENV,
            "cloud.provider": CLOUD_PROVIDER,
            "service.namespace": "observability-lab",
            "host.name": os.getenv("HOSTNAME", "local"),
        }
    )

    # -- 2. TRAZAS ------------------------------------------------------------
    # BatchSpanProcessor agrupa spans en memoria y los envia en lotes: reduce
    # drasticamente el overhead de red frente a un exporter sincrono.
    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True))
    )
    trace.set_tracer_provider(tracer_provider)
    tel.tracer = trace.get_tracer(service_name, APP_VERSION)
    tel._providers.append(tracer_provider)

    # -- 3. METRICAS ----------------------------------------------------------
    # Dos readers en paralelo, a proposito:
    #   - OTLP push  -> el Collector centraliza y reexporta (camino de produccion)
    #   - Prometheus -> /metrics local, permite validar sin depender del Collector
    otlp_reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=OTEL_ENDPOINT, insecure=True),
        export_interval_millis=METRIC_EXPORT_INTERVAL_MS,
    )
    prometheus_reader = PrometheusMetricReader()
    meter_provider = MeterProvider(
        resource=resource,
        metric_readers=[otlp_reader, prometheus_reader],
        views=_vistas_histogramas(),
    )
    metrics.set_meter_provider(meter_provider)
    tel.meter = metrics.get_meter(service_name, APP_VERSION)
    tel._providers.append(meter_provider)

    # Servidor HTTP que expone el registry de prometheus_client en /metrics
    start_http_server(PROMETHEUS_PORT)

    # -- 4. LOGS --------------------------------------------------------------
    # Los logs viajan por OTLP hacia el Collector (y de ahi a Loki) llevando el
    # trace_id dentro del propio LogRecord, no solo en el texto.
    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(
        BatchLogRecordProcessor(OTLPLogExporter(endpoint=OTEL_ENDPOINT, insecure=True))
    )
    set_logger_provider(logger_provider)
    tel._providers.append(logger_provider)

    # El LoggingHandler puentea el logging estandar de Python hacia OTLP.
    # Se suma al handler de stdout: el log sale por ambos caminos.
    otel_handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
    logging.getLogger().addHandler(otel_handler)

    # -- 5. Auto-instrumentacion de librerias ---------------------------------
    # HTTPX: inyecta el header W3C `traceparent` en cada request saliente.
    # Esa inyeccion es la que propaga el contexto de service-a a service-b.
    HTTPXClientInstrumentor().instrument(tracer_provider=tracer_provider)

    if instrument_db:
        from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor

        # Psycopg2: un span por query SQL, con db.statement como atributo.
        Psycopg2Instrumentor().instrument(tracer_provider=tracer_provider)

    tel.logger.info(
        "Telemetria inicializada",
        extra={
            "otlp_endpoint": OTEL_ENDPOINT,
            "prometheus_port": PROMETHEUS_PORT,
            "pilares": "traces+metrics+logs",
        },
    )
    return tel


def instrument_fastapi(app, tel):
    """
    Instrumenta la app FastAPI. Se llama DESPUES de crear la app para que el
    middleware de OTel envuelva todas las rutas ya registradas.

    Los health checks se excluyen: son ruido que infla el volumen de trazas sin
    aportar informacion de negocio (tambien se filtran en el Collector).
    """
    if not tel.enabled:
        return

    from opentelemetry import trace
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

    FastAPIInstrumentor.instrument_app(
        app,
        tracer_provider=trace.get_tracer_provider(),
        excluded_urls="health,metrics",
    )


def current_trace_id():
    """trace_id activo en hex de 32 digitos; cadena vacia si no hay traza."""
    if not OTEL_ENABLED:
        return ""

    from opentelemetry import trace

    ctx = trace.get_current_span().get_span_context()
    return format(ctx.trace_id, "032x") if ctx and ctx.is_valid else ""


def span_status_error(span, exc):
    """Marca un span como fallido y adjunta la excepcion (si hay instrumentacion)."""
    if not OTEL_ENABLED:
        return

    from opentelemetry import trace

    span.record_exception(exc)
    span.set_status(trace.Status(trace.StatusCode.ERROR, str(exc)))
