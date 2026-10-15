# Pipeline de Observabilidad End-to-End con OpenTelemetry

**Laboratorio — Maestría en Arquitectura de Software · Observabilidad en Ambientes Productivos**

Pipeline completo que captura las **tres señales** de observabilidad (métricas, logs y trazas distribuidas) desde dos microservicios instrumentados con el SDK de OpenTelemetry, las centraliza en un OTel Collector y las correlaciona a través del `trace_id` siguiendo el estándar W3C TraceContext.

---

## Origen del proyecto

Este repositorio parte del laboratorio base publicado en
[mafeopa/oTelLabs](https://github.com/mafeopa/oTelLabs), del que se conservan la
arquitectura y las decisiones de diseño principales:

- El flujo `service-a → service-b` con PostgreSQL en ambos extremos
- FastAPI instrumentado con el SDK de OpenTelemetry
- El OTel Collector como punto único de entrada de las señales
- El stack de backends Jaeger · Tempo · Prometheus · Grafana
- La nomenclatura de los custom spans de negocio y los 4 SLIs del dashboard

La implementación se reescribió para que el pipeline funcione de extremo a
extremo y para cubrir los puntos que faltaban. Los cambios principales:

| Área | Qué se corrigió o añadió |
|---|---|
| Arranque | Ruta de credenciales de GCP embebida en el compose y exporter `googlecloud` en el pipeline de logs: impedían levantar el stack sin una cuenta de Google |
| Logs | Se añadió **Loki** y la emisión de logs por OTLP. El datasource de Jaeger ya apuntaba a un `loki` que no existía, así que la correlación traza↔log no podía funcionar |
| Métricas | `PrometheusMetricReader` estaba importado pero no se usaba, y los puertos de scraping no coincidían con los publicados en el compose |
| Histogramas | Fronteras explícitas de bucket: los valores por defecto asumen milisegundos y volvían inservible el p99 medido en segundos |
| Telemetría | `services/common/telemetry.py` centraliza los tres pilares y permite desactivarlos con `OTEL_ENABLED`, que es lo que hace posible el benchmark comparativo |
| Benchmark | Línea base real sin instrumentación, ventanas temporales por escenario y medición de recursos desde el host |
| IaC | Terraform para GCP Cloud Run y AWS ECS Fargate con el Collector como sidecar |
| Verificación | `verify-pipeline.sh` comprueba la correlación consultando las APIs de los backends, en lugar de inspeccionar la interfaz a mano |

### Equivalencia de rutas con el repositorio base

La estructura se reorganizó para que los microservicios compartan un módulo de
instrumentación común en lugar de duplicarlo. Si un enunciado o una guía
menciona una ruta del repositorio original, su equivalente aquí es:

| Repositorio base | Aquí |
|---|---|
| `service-a/main.py` | `services/service-a/main.py` |
| `service-b/main.py` | `services/service-b/main.py` |
| `service-a/requirements.txt` | `services/requirements.txt` (compartido) |
| `otel-collector/collector-config.yaml` | `otel-collector/collector-local.yaml` |
| `grafana/` | `observability/grafana/` |
| `prometheus/` | `observability/prometheus/` |
| `tempo/` | `observability/tempo/` |
| `benchmark/k6_benchmark.js` | `benchmark/load.js` |
| `k8s/gcp/`, `k8s/aws/` | `terraform/gcp/`, `terraform/aws/` |
| — | `services/common/telemetry.py`, `services/common/datastore.py` |

El agrupamiento bajo `services/` es deliberado: **añadir un tercer
microservicio** solo requiere importar `common/telemetry.py`, en lugar de
copiar por tercera vez el bootstrap de los tres pilares. El contexto de build
de Docker es `services/`, por eso cada servicio puede acceder a `common/`.

---

## Tabla de contenidos

1. [Arquitectura](#arquitectura)
2. [Puesta en marcha](#puesta-en-marcha)
3. [Verificación del pipeline](#verificación-del-pipeline)
4. [Correlación cross-signal](#correlación-cross-signal)
5. [Benchmark de overhead](#benchmark-de-overhead)
6. [Despliegue en la nube](#despliegue-en-la-nube)
7. [Estructura del repositorio](#estructura-del-repositorio)
8. [Decisiones de diseño](#decisiones-de-diseño)
9. [Resolución de problemas](#resolución-de-problemas)

---

## Arquitectura

```
                    ┌──────────────────────────┐
                    │   cliente / k6 benchmark │
                    └────────────┬─────────────┘
                                 │ GET /order/{id}
                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│  service-a  ·  FastAPI :8000  ·  orquestador                         │
│                                                                       │
│  Auto-instrumentación:  FastAPI · HTTPX · psycopg2                   │
│  Custom spans:          order.process → fetch.order.db               │
│                         → call.service-b.inventory                   │
│                         → order.compute_total                        │
└───────┬──────────────────────────────────────┬───────────────────────┘
        │ SQL                                  │ HTTP + header traceparent
        ▼                                      ▼
┌───────────────┐              ┌──────────────────────────────────────┐
│  PostgreSQL   │◀─────────────│  service-b · FastAPI :8001           │
│  orders       │     SQL      │                                      │
│  inventory    │              │  Custom spans: inventory.lookup.db   │
└───────────────┘              │                inventory.validate... │
                               └──────────────────────────────────────┘
        │                                      │
        └──────────────┬───────────────────────┘
                       │ OTLP/gRPC :4317  (trazas + métricas + logs)
                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│  OTel Collector                                                      │
│                                                                       │
│  receivers:   otlp (gRPC+HTTP) · docker_stats                        │
│  processors:  memory_limiter → resourcedetection → resource          │
│               → filter/health → attributes → batch                   │
└───┬──────────────┬──────────────────┬───────────────────┬────────────┘
    │ trazas       │ trazas           │ métricas          │ logs
    ▼              ▼                  ▼                   ▼
┌─────────┐  ┌──────────┐      ┌─────────────┐     ┌──────────┐
│ Jaeger  │  │  Tempo   │      │ Prometheus  │     │   Loki   │
│ :16686  │  │  :3200   │      │   :9090     │     │  :3100   │
└────┬────┘  └────┬─────┘      └──────┬──────┘     └────┬─────┘
     └────────────┴───────────────────┴─────────────────┘
                              │
                              ▼
                    ┌───────────────────┐
                    │  Grafana  :3000   │
                    │  correlación por  │
                    │     trace_id      │
                    └───────────────────┘
```

### Componentes

| Componente | Imagen | Puerto | Función |
|---|---|---|---|
| service-a | `otel-lab/service-a:1.0.0` | 8000 | Orquestador: DB + llamada a service-b |
| service-b | `otel-lab/service-b:1.0.0` | 8001 | Inventario (downstream) |
| PostgreSQL | `postgres:16-alpine` | 5432 | `orders` e `inventory` |
| OTel Collector | `otel/opentelemetry-collector-contrib:0.103.0` | 4317/4318 | Entrada única de las tres señales |
| Jaeger | `jaegertracing/all-in-one:1.58` | 16686 | Backend de trazas (UI de referencia) |
| Tempo | `grafana/tempo:2.5.0` | 3200 | Backend de trazas nativo de Grafana |
| Prometheus | `prom/prometheus:v2.52.0` | 9090 | Backend de métricas |
| Loki | `grafana/loki:3.2.1` | 3100 | Backend de logs |
| Grafana | `grafana/grafana:11.3.0` | 3000 | Visualización y correlación |

---

## Puesta en marcha

### Requisitos

- Docker Desktop con Docker Compose v2
- Python 3.9+ en el host (solo para el script de análisis del benchmark)
- ~4 GB de RAM libres

### Arranque

```bash
docker compose up -d --build
```

El primer arranque descarga las imágenes y construye los servicios (5–15 minutos según la conexión). Los siguientes son de segundos.

### Comprobación

```bash
docker compose ps
```

Los ocho contenedores deben aparecer como `Up`, y `postgres`, `jaeger`, `loki`, `otel-collector`, `service-a` y `service-b` como `healthy`.

### Accesos

| Servicio | URL | Credenciales |
|---|---|---|
| service-a (OpenAPI) | http://localhost:8000/docs | — |
| service-b (OpenAPI) | http://localhost:8001/docs | — |
| **Grafana** | http://localhost:3000 | `admin` / `admin` |
| **Jaeger UI** | http://localhost:16686 | — |
| Prometheus | http://localhost:9090 | — |
| Loki | http://localhost:3100 | — |
| Tempo | http://localhost:3200 | — |
| Collector · zPages | http://localhost:55679/debug/servicez | — |
| Collector · health | http://localhost:13133 | — |

### Primera petición

```bash
curl http://localhost:8000/order/ORD-0001
```

La respuesta incluye el `trace_id` del request, que sirve de punto de entrada para seguirlo por las tres señales:

```json
{
  "order": { "id": "ORD-0001", "product": "mouse-wireless", "quantity": 2, ... },
  "inventory": { "available": 980, "stock_level": "healthy", ... },
  "total_amount": 174.0,
  "fulfillable": true,
  "trace_id": "d236b3bd43faec1e0e8698df474610c6"
}
```

### Apagado

```bash
docker compose down        # conserva los datos
docker compose down -v     # elimina también los volúmenes
```

---

## Verificación del pipeline

El repositorio incluye una verificación automatizada que no depende de inspeccionar la interfaz a mano: dispara un request real y consulta **las APIs de cada backend** para comprobar que ese mismo `trace_id` aparece en las tres señales.

```bash
bash scripts/verify-pipeline.sh
```

Comprueba, en orden:

1. El `trace_id` devuelto tiene el formato W3C (32 hexadecimales).
2. La traza existe en Jaeger.
3. **La traza contiene spans de `service-a` Y de `service-b`** — prueba de que el contexto se propagó.
4. Los custom spans de negocio están presentes.
5. Loki tiene líneas de log filtrables por ese `trace_id`.
6. Prometheus tiene series para los SLIs.
7. El Collector no está rechazando ni descartando señales.

Salida esperada:

```
  Comprobaciones superadas: 15
  Comprobaciones fallidas:  0

  PIPELINE VERIFICADO: las tres señales correlacionan por trace_id
```

---

## Correlación cross-signal

El `trace_id` es el pivote que une las tres señales. La navegación está configurada **en ambos sentidos** en `observability/grafana/provisioning/datasources/datasources.yaml`:

```
        ┌──────────────────────────────────────────────┐
        │                                              │
        ▼                                              │
 ┌──────────────┐  trace_id   ┌───────────────┐       │
 │     LOGS     │────────────▶│    TRAZAS     │       │
 │    (Loki)    │◀────────────│ (Jaeger/Tempo)│       │
 └──────────────┘             └───────┬───────┘       │
        ▲                             │ span metrics  │
        │                             ▼               │
        │                      ┌──────────────┐       │
        └──────────────────────│   MÉTRICAS   │───────┘
                exemplar       │ (Prometheus) │
                               └──────────────┘
```

| Salto | Mecanismo | Dónde se configura |
|---|---|---|
| Log → Traza | `derivedFields` sobre el `trace_id` | datasource Loki |
| Traza → Log | `tracesToLogsV2` con query LogQL | datasources Jaeger y Tempo |
| Traza → Métrica | `tracesToMetrics` | datasources Jaeger y Tempo |
| Métrica → Traza | `exemplarTraceIdDestinations` | datasource Prometheus |

### Demostración manual

**De la traza al log** — en Jaeger (http://localhost:16686), abre una traza de `service-a`, despliega cualquier span y pulsa **Logs for this span**.

**Del log a la traza** — en Grafana → *Explore* → datasource **Loki**:

```logql
{service_name="service-a"} | trace_id = `<tu-trace-id>`
```

Al expandir una línea aparece el enlace **Ver traza en Jaeger**.

**Verificación de la propagación W3C** — el flujo `service-a → service-b` propaga el header `traceparent` con formato `00-<trace_id>-<span_id>-<flags>`. Que ambos servicios compartan el mismo `trace_id` es lo que confirma que la propagación funciona:

```bash
curl -s http://localhost:8000/order/ORD-0001 | python -m json.tool
```

El `trace_id` de la raíz y el que viene anidado dentro de `inventory` (producido por service-b) deben ser **idénticos**.

---

## Benchmark de overhead

### Diseño de la medición

El benchmark compara dos despliegues que corren **exactamente la misma imagen y el mismo código**; la única diferencia es la variable `OTEL_ENABLED`:

| | Línea base | Instrumentado |
|---|---|---|
| Contenedores | `service-a-baseline`, `service-b-baseline` | `service-a`, `service-b` |
| `OTEL_ENABLED` | `false` | `true` |
| SDK de OTel | nunca se carga en memoria | activo (3 pilares) |
| Límites | 1.0 CPU / 512 MiB | 1.0 CPU / 512 MiB |

Con `OTEL_ENABLED=false`, `common/telemetry.py` devuelve implementaciones no-op y ni siquiera importa el SDK. Mantener límites de recursos idénticos es lo que impide confundir el costo de OTel con una diferencia de CPU disponible.

**Las métricas se toman de dos fuentes independientes**, para no pedirle al proceso instrumentado que se mida a sí mismo:

- **Latencia y throughput** → k6, desde el cliente.
- **CPU y memoria** → receiver `docker_stats` del Collector, desde el host.

### Dos regímenes de carga

La medición se ejecuta en dos niveles de concurrencia porque responden a preguntas distintas:

| Régimen | VUs | Qué mide |
|---|---|---|
| **Carga moderada** | 25 | La CPU no está topada, así que el consumo extra de OTel es directamente observable → **cuánto cuesta instrumentar** |
| **Saturación** | 75 | Ambos escenarios agotan el límite de 1.0 CPU. El costo no puede aparecer como más CPU y se paga en throughput → **cuánta capacidad cuesta** |

Reportar solo el escenario saturado sería engañoso: la CPU sale casi idéntica en ambos casos (~100 %) no porque la instrumentación salga gratis, sino porque **no queda CPU que consumir**. El límite del contenedor actúa como techo y enmascara el costo real.

### Ejecución

```bash
# Régimen de saturación (el que pide el enunciado: 50–100 VUs, 5 min)
ETIQUETA=saturacion-75vus VUS=75 bash scripts/run-benchmark.sh

# Régimen de carga moderada
ETIQUETA=moderada-25vus VUS=25 bash scripts/run-benchmark.sh
```

El script levanta la línea base, la calienta, ejecuta la carga, apaga esos contenedores para liberar CPU, repite contra los instrumentados y ejecuta el análisis comparativo. `ETIQUETA` archiva los resultados en su propia subcarpeta para que las dos corridas no se pisen.

### Resultados

```
benchmark/results/<etiqueta>/
  k6-baseline.json       métricas de cliente, línea base
  k6-instrumented.json   métricas de cliente, instrumentado
  overhead.md            tabla comparativa
  overhead.json          datos crudos que consume el reporte
  ventanas.json          intervalo de carga de cada escenario
```

El análisis puede re-ejecutarse sin repetir la carga:

```bash
python benchmark/analyze_overhead.py --prometheus http://localhost:9090
```

### Reporte técnico

```bash
python docs/generar_reporte.py    # inyecta los resultados reales en el HTML
bash scripts/generar-pdf.sh       # convierte a PDF con Chrome headless
```

El reporte lee `overhead.json` de cada régimen disponible, de modo que las cifras del documento y las de la medición nunca se desincronizan.

---

## Despliegue en la nube

La infraestructura está descrita como código en `terraform/`, parametrizada y sin ningún valor de cuenta embebido en los archivos versionados.

En ambas nubes el Collector se despliega con el **patrón sidecar**: corre como un contenedor más junto a la aplicación, compartiendo el espacio de red, de modo que la app exporta a `localhost:4317` sin exponer ningún puerto de telemetría.

### GCP — Cloud Run

```bash
cd terraform/gcp
cp terraform.tfvars.example terraform.tfvars   # completar project_id y db_password
terraform init
terraform plan
terraform apply
```

Crea Artifact Registry, una service account con permisos mínimos de escritura de telemetría, los secretos, Cloud SQL (opcional) y dos servicios de Cloud Run con el Collector como sidecar. Los exporters apuntan a **Cloud Trace**, **Cloud Logging** y **Managed Prometheus**.

> Las imágenes deben publicarse en Artifact Registry antes del primer `apply`. El output `comandos_publicacion` imprime la secuencia exacta.

### AWS — ECS Fargate

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform plan && terraform apply
```

Crea VPC, ECR, cluster ECS, ALB, Cloud Map y dos servicios Fargate con el Collector como sidecar, exportando a **X-Ray**, **CloudWatch Logs** y **CloudWatch Metrics (EMF)**.

### Configuraciones del Collector por entorno

| Archivo | Entorno | Backends |
|---|---|---|
| `otel-collector/collector-local.yaml` | Docker Compose | Jaeger · Tempo · Prometheus · Loki |
| `otel-collector/collector-gcp.yaml` | Cloud Run | Cloud Trace · Cloud Logging · Managed Prometheus |
| `otel-collector/collector-aws.yaml` | ECS Fargate | X-Ray · CloudWatch Logs · CloudWatch EMF |

La estructura de pipelines (receivers, processors, orden de los procesadores) es idéntica en los tres: solo cambian los exporters. Esa simetría es intencional — permite validar el comportamiento en local y confiar en que la nube se comporta igual.

---

## Estructura del repositorio

```
.
├── docker-compose.yaml              Stack completo (perfiles: baseline, load)
├── services/
│   ├── requirements.txt             Dependencias compartidas, versiones fijadas
│   ├── common/telemetry.py          Bootstrap de los 3 pilares + modo no-op
│   ├── service-a/                   Orquestador
│   └── service-b/                   Inventario
├── otel-collector/
│   ├── collector-local.yaml         Entorno local
│   ├── collector-gcp.yaml           Cloud Run
│   └── collector-aws.yaml           ECS Fargate
├── observability/
│   ├── prometheus/prometheus.yaml
│   ├── loki/loki.yaml
│   ├── tempo/tempo.yaml
│   └── grafana/
│       ├── provisioning/datasources/   ← correlación cross-signal
│       ├── provisioning/dashboards/
│       └── dashboards/otel-lab.json    ← 11 paneles
├── benchmark/
│   ├── load.js                      Script de carga k6
│   └── analyze_overhead.py          Análisis comparativo
├── terraform/
│   ├── gcp/                         Cloud Run + sidecar
│   └── aws/                         ECS Fargate + sidecar
├── scripts/
│   ├── init-db.sql                  Esquema y datos semilla
│   ├── verify-pipeline.sh           Verificación cross-signal automatizada
│   └── run-benchmark.sh             Orquestación del benchmark
└── docs/
    └── evidencias/                  Capturas de Jaeger, Grafana y dashboards
```

---

## Decisiones de diseño

### Por qué `OTEL_ENABLED` en vez de dos imágenes distintas

Un benchmark con dos bases de código separadas no mide solo el overhead de OTel: mide también las diferencias accidentales entre ambas. Con un interruptor sobre la misma imagen, la única variable que cambia es la instrumentación. Los imports del SDK están diferidos dentro de `setup_telemetry()`, así que en modo línea base ni siquiera se cargan en memoria.

### Por qué dos readers de métricas

`PeriodicExportingMetricReader` (push OTLP al Collector) es el camino de producción. `PrometheusMetricReader` (scraping en `:9464`) existe como control: permite comprobar que el Collector no pierde ni altera métricas por el camino.

Esto duplica cada serie en Prometheus, distinguidas por el label `source` (`collector` o `direct`). **Todas las queries del dashboard filtran `source="collector"`**; sin ese filtro, el throughput se contaría dos veces.

### Por qué buckets de histograma explícitos

Los buckets por defecto del SDK (`[0, 5, 10, 25, ..., 10000]`) están pensados para milisegundos. Este laboratorio registra la latencia en segundos, siguiendo la convención de Prometheus, así que casi todas las muestras caerían en el primer bucket `[0, 5)` y `histogram_quantile` devolvería un p99 cercano a 5 s con independencia de la latencia real. Las vistas de `common/telemetry.py` sustituyen esas fronteras por las estándar de latencia HTTP.

### Por qué `memory_limiter` va primero

El orden de los procesadores no es arbitrario. `memory_limiter` debe preceder a `batch`: si fuera al revés, el lote ya habría reservado la memoria que se intenta limitar. Y `batch` va al final, justo antes de los exporters, que es donde la agrupación reduce llamadas de red.

### Por qué se filtran los health checks

Docker sondea `/health` cada 10 s en cada contenedor. Sin el procesador `filter/health`, esos sondeos dominarían el volumen de trazas sin aportar ninguna información de negocio. Se filtran en dos niveles: en el SDK (`excluded_urls`) y en el Collector.

### Por qué Jaeger **y** Tempo

Jaeger aporta la interfaz de referencia que pide el entregable. Tempo se integra de forma nativa con Grafana y su `metrics_generator` deriva métricas RED y el mapa de servicios a partir de las propias trazas, lo que añade una tercera vía de correlación entre trazas y métricas.

### Por qué un pool de conexiones

Sin pool, cada request pagaría el handshake TCP y la autenticación de PostgreSQL. Ese costo dominaría la medición y se le atribuiría a OpenTelemetry una latencia que en realidad es de la base de datos.

---

## Resolución de problemas

### El Collector aparece como `unhealthy`

La imagen es *distroless*: no incluye shell, `curl` ni `wget`, por lo que no puede sondear su propio endpoint de salud. El healthcheck ejecuta el binario del Collector. Para verificar el estado real desde el host:

```bash
curl http://localhost:13133/
```

### No llegan trazas a Jaeger

Los exportadores trabajan por lotes: el `BatchSpanProcessor` del SDK y el procesador `batch` del Collector introducen hasta ~10 s de retardo. Espera y revisa los contadores internos:

```bash
curl -s http://localhost:8888/metrics | grep otelcol_receiver_accepted_spans
```

### No hay logs en Loki

```bash
docker compose logs otel-collector | grep -i loki
curl -s "http://localhost:3100/loki/api/v1/labels"
```

La etiqueta `service_name` debe existir. Loki la deriva del atributo `service.name` del Resource de OTel.

### Los percentiles de latencia parecen anclados a un valor

Tras cambiar los buckets de un histograma, las series antiguas conviven con las nuevas en Prometheus y `sum by (le)` las agrega. El exporter las expira en 5 minutos (`metric_expiration`); si quieres limpiar de inmediato:

```bash
docker compose down -v && docker compose up -d --build
```

### Faltan métricas de CPU o memoria de los contenedores

El receiver `docker_stats` necesita el socket de Docker. En Docker Desktop para Windows debe estar habilitada la exposición del daemon. Verificación:

```bash
curl -s http://localhost:9090/api/v1/query?query=container_cpu_utilization_ratio
```

### El puerto ya está en uso

Puertos ocupados por el stack: 3000, 3100, 3200, 4317, 4318, 5432, 8000, 8001, 8888, 8889, 9090, 9464, 9465, 13133, 16686, 55679. Ajusta el mapeo en `docker-compose.yaml` si alguno colisiona.
