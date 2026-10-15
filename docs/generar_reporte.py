#!/usr/bin/env python3
"""
generar_reporte.py - Construye el reporte tecnico del laboratorio.

Lee los resultados REALES del benchmark (benchmark/results/overhead.json) y
genera docs/reporte-tecnico.html, listo para convertir a PDF.

Que los numeros se inyecten desde el JSON de la medicion, en lugar de
transcribirse a mano, evita que el reporte y la evidencia se desincronicen.

Uso:
    python docs/generar_reporte.py
    bash scripts/generar-pdf.sh      # convierte el HTML a PDF con Chrome
"""

import json
import os
import sys
from datetime import datetime

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTADOS = os.path.join(RAIZ, "benchmark", "results")
SALIDA_HTML = os.path.join(RAIZ, "docs", "reporte-tecnico.html")


# El benchmark se ejecuta en dos regimenes de carga. Cada uno responde una
# pregunta distinta y por eso se reportan ambos:
#
#   - Carga moderada: la CPU no esta topada, asi que el consumo adicional de
#     OpenTelemetry es visible como tal. Mide el overhead PURO.
#   - Saturacion: la CPU esta al limite, de modo que el costo de la telemetria
#     no puede manifestarse como mas CPU y se paga en throughput y latencia.
#     Mide el impacto en CAPACIDAD.
REGIMENES = [
    {
        "clave": "moderada",
        "carpeta": "moderada-25vus",
        "titulo": "Carga moderada (25 usuarios concurrentes)",
        "descripcion": (
            "La CPU no esta saturada, por lo que el consumo adicional de "
            "OpenTelemetry es directamente observable. Es la medicion del "
            "overhead en si mismo."
        ),
    },
    {
        "clave": "saturacion",
        "carpeta": "saturacion-75vus",
        "titulo": "Saturacion (75 usuarios concurrentes)",
        "descripcion": (
            "Ambos escenarios agotan el limite de 1.0 CPU por contenedor. Al no "
            "haber CPU libre, el costo de la telemetria no puede aparecer como "
            "mas consumo: se traduce en menos peticiones atendidas y mas "
            "latencia. Es la medicion del impacto en la capacidad del servicio."
        ),
    },
]


def cargar(nombre, subcarpeta=None):
    base = RESULTADOS if subcarpeta is None else os.path.join(RESULTADOS, subcarpeta)
    ruta = os.path.join(base, nombre)
    if not os.path.exists(ruta):
        return None
    try:
        with open(ruta, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as exc:
        print("  [aviso] no se pudo leer " + nombre + ": " + str(exc))
        return None


def cargar_regimenes():
    """Devuelve los regimenes que tienen resultados disponibles."""
    disponibles = []
    for reg in REGIMENES:
        overhead = cargar("overhead.json", reg["carpeta"])
        base = cargar("k6-baseline.json", reg["carpeta"])
        instr = cargar("k6-instrumented.json", reg["carpeta"])
        if overhead and base and instr:
            disponibles.append(
                dict(reg, overhead=overhead, base=base, instr=instr)
            )
            print("  " + reg["carpeta"] + ": encontrado")
        else:
            print("  " + reg["carpeta"] + ": sin datos")
    return disponibles


def filas_tabla(overhead):
    """Convierte la tabla del analisis en filas HTML."""
    if not overhead or "tabla" not in overhead:
        return (
            '<tr><td colspan="5" class="sin-datos">Benchmark no ejecutado. '
            "Correr <code>bash scripts/run-benchmark.sh</code> y regenerar "
            "este reporte.</td></tr>"
        )

    filas = []
    for f in overhead["tabla"]:
        # Resalta en rojo los overheads positivos superiores al 10 %.
        clase = ""
        pct = f.get("delta_pct", "")
        try:
            valor = float(pct.replace("%", "").replace("+", "").strip())
            if valor > 10:
                clase = ' class="alto"'
            elif valor < 0:
                clase = ' class="mejora"'
        except (ValueError, AttributeError):
            pass

        filas.append(
            "<tr><td><strong>"
            + f["metrica"]
            + "</strong></td><td>"
            + f["base"]
            + "</td><td>"
            + f["instrumentado"]
            + "</td><td>"
            + f["delta_abs"]
            + "</td><td"
            + clase
            + ">"
            + f["delta_pct"]
            + "</td></tr>"
        )
    return "\n".join(filas)


def bloque_condiciones(base, instr):
    if not base or not instr:
        return "<p class='sin-datos'>Sin datos de benchmark.</p>"

    return (
        "<ul>"
        "<li><strong>Usuarios concurrentes:</strong> "
        + str(instr.get("vus_maximos"))
        + " VUs (rampa de 30 s + meseta de "
        + str(instr.get("duracion_meseta"))
        + ")</li>"
        "<li><strong>Peticiones linea base:</strong> "
        + "{:,}".format(int(base.get("requests_totales") or 0))
        + "</li>"
        "<li><strong>Peticiones instrumentado:</strong> "
        + "{:,}".format(int(instr.get("requests_totales") or 0))
        + "</li>"
        "<li><strong>Limites por contenedor:</strong> 1.0 CPU / 512 MiB "
        "(identicos en ambos escenarios)</li>"
        "<li><strong>Mezcla de trafico:</strong> 85 % consulta de pedido "
        "(A &rarr; DB &rarr; B &rarr; DB), 10 % listado, 5 % pedido "
        "inexistente</li>"
        "</ul>"
    )


def bloque_correlacion(instr):
    if not instr:
        return ""

    con_trace = instr.get("respuestas_con_trace_id") or 0
    total = instr.get("requests_totales") or 0
    pct = (100.0 * con_trace / total) if total else 0

    return (
        "<p>Durante el escenario instrumentado, <strong>"
        + "{:,}".format(int(con_trace))
        + "</strong> respuestas incluyeron un <code>trace_id</code> con formato "
        "W3C valido (32 digitos hexadecimales), sobre un total de "
        + "{:,}".format(int(total))
        + " peticiones (" + "{:.1f}".format(pct) + " %). El resto corresponde a "
        "los endpoints <code>/orders</code> y a las consultas de pedidos "
        "inexistentes, que por diseno no devuelven <code>trace_id</code> en el "
        "cuerpo de la respuesta.</p>"
    )


def bloque_resultados(regimenes):
    """Una subseccion con su tabla por cada regimen de carga medido."""
    if not regimenes:
        return (
            "<p class='sin-datos'>Benchmark no ejecutado. Correr "
            "<code>bash scripts/run-benchmark.sh</code> y regenerar este "
            "reporte.</p>"
        )

    partes = []
    for reg in regimenes:
        partes.append("<h3>5.3." + str(len(partes) + 1) + " " + reg["titulo"] + "</h3>")
        partes.append("<p>" + reg["descripcion"] + "</p>")
        partes.append(bloque_condiciones(reg["base"], reg["instr"]))
        partes.append(
            '<table><tr><th>Metrica</th><th>Sin OTel</th><th>Con OTel</th>'
            "<th>Diferencia</th><th>Overhead</th></tr>"
            + filas_tabla(reg["overhead"])
            + "</table>"
        )

    return "\n".join(partes)


def generar():
    print("Leyendo resultados del benchmark...")
    regimenes = cargar_regimenes()

    # El bloque de correlacion usa el regimen mas cargado disponible, que es el
    # que acumula mas peticiones y por tanto mas evidencia de trace_id.
    instr_principal = None
    if regimenes:
        instr_principal = max(
            (r["instr"] for r in regimenes),
            key=lambda d: d.get("requests_totales") or 0,
        )

    fecha = datetime.now().strftime("%d/%m/%Y")

    html = PLANTILLA.format(
        fecha=fecha,
        resultados=bloque_resultados(regimenes),
        correlacion=bloque_correlacion(instr_principal),
    )

    os.makedirs(os.path.dirname(SALIDA_HTML), exist_ok=True)
    with open(SALIDA_HTML, "w", encoding="utf-8") as fh:
        fh.write(html)

    print("\nReporte generado: " + SALIDA_HTML)
    print("Para producir el PDF:  bash scripts/generar-pdf.sh")
    return 0


# =============================================================================
# Plantilla del reporte
# =============================================================================
PLANTILLA = r"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<title>Reporte Tecnico - Pipeline de Observabilidad con OpenTelemetry</title>
<style>
  @page {{ size: A4; margin: 18mm 16mm 20mm 16mm; }}

  :root {{
    --tinta:   #1a2332;
    --suave:   #5a6778;
    --acento:  #1c3d5a;
    --linea:   #d4dae2;
    --fondo:   #f6f8fa;
    --alerta:  #b4453c;
    --ok:      #2d7d4f;
  }}

  * {{ box-sizing: border-box; }}

  body {{
    font-family: "Segoe UI", -apple-system, system-ui, sans-serif;
    font-size: 10.5pt;
    line-height: 1.6;
    color: var(--tinta);
    margin: 0 auto;
    max-width: 190mm;
    padding: 10mm;
    background: #fff;
  }}

  h1 {{
    font-size: 21pt;
    line-height: 1.25;
    margin: 0 0 6px;
    color: var(--acento);
    letter-spacing: -0.4px;
  }}

  h2 {{
    font-size: 14pt;
    margin: 26px 0 10px;
    padding-bottom: 5px;
    border-bottom: 2px solid var(--acento);
    color: var(--acento);
    page-break-after: avoid;
  }}

  h3 {{
    font-size: 11.5pt;
    margin: 18px 0 7px;
    color: var(--tinta);
    page-break-after: avoid;
  }}

  p {{ margin: 0 0 10px; text-align: justify; }}
  ul, ol {{ margin: 0 0 12px; padding-left: 20px; }}
  li {{ margin-bottom: 5px; }}

  code {{
    font-family: "Cascadia Mono", Consolas, monospace;
    font-size: 9pt;
    background: var(--fondo);
    padding: 1px 4px;
    border-radius: 3px;
    border: 1px solid var(--linea);
  }}

  pre {{
    font-family: "Cascadia Mono", Consolas, monospace;
    font-size: 8.2pt;
    line-height: 1.45;
    background: var(--fondo);
    border: 1px solid var(--linea);
    border-left: 3px solid var(--acento);
    border-radius: 4px;
    padding: 10px 12px;
    overflow-x: auto;
    page-break-inside: avoid;
    white-space: pre;
  }}

  pre code {{ background: none; border: none; padding: 0; font-size: inherit; }}

  table {{
    width: 100%;
    border-collapse: collapse;
    margin: 12px 0 16px;
    font-size: 9.3pt;
    page-break-inside: avoid;
  }}

  th {{
    background: var(--acento);
    color: #fff;
    text-align: left;
    padding: 7px 9px;
    font-weight: 600;
  }}

  td {{ padding: 6px 9px; border-bottom: 1px solid var(--linea); }}
  tr:nth-child(even) td {{ background: #fafbfc; }}

  td.alto   {{ color: var(--alerta); font-weight: 600; }}
  td.mejora {{ color: var(--ok); font-weight: 600; }}

  .sin-datos {{ color: var(--suave); font-style: italic; }}

  .portada {{
    border-bottom: 3px solid var(--acento);
    padding-bottom: 16px;
    margin-bottom: 8px;
  }}

  .subtitulo {{
    font-size: 11.5pt;
    color: var(--suave);
    margin: 4px 0 14px;
  }}

  .meta {{
    font-size: 9.5pt;
    color: var(--suave);
    line-height: 1.8;
  }}

  .meta strong {{ color: var(--tinta); }}

  .nota {{
    background: #fdf6e3;
    border-left: 3px solid #c89b3c;
    padding: 10px 13px;
    margin: 13px 0;
    font-size: 9.6pt;
    page-break-inside: avoid;
  }}

  .destacado {{
    background: var(--fondo);
    border-left: 3px solid var(--acento);
    padding: 10px 13px;
    margin: 13px 0;
    page-break-inside: avoid;
  }}

  .salto {{ page-break-before: always; }}

  figure {{ margin: 14px 0; page-break-inside: avoid; }}

  figcaption {{
    font-size: 8.8pt;
    color: var(--suave);
    text-align: center;
    margin-top: 5px;
    font-style: italic;
  }}
</style>
</head>
<body>

<div class="portada">
  <h1>Pipeline de Observabilidad End-to-End<br>con OpenTelemetry</h1>
  <div class="subtitulo">
    Instrumentacion de microservicios, correlacion cross-signal y analisis de
    overhead
  </div>
  <div class="meta">
    <strong>Laboratorio:</strong> Pipeline OpenTelemetry con Jaeger y Prometheus<br>
    <strong>Programa:</strong> Maestria en Arquitectura de Software &mdash; Universidad de La Sabana<br>
    <strong>Asignatura:</strong> Observabilidad en Ambientes Productivos<br>
    <strong>Autor:</strong> Julian Miranda<br>
    <strong>Fecha:</strong> {fecha}
  </div>
</div>

<h2>1. Introduccion y objetivo</h2>

<p>Este trabajo implementa un pipeline de observabilidad completo sobre una
aplicacion de microservicios, capturando las tres senales de telemetria
&mdash;metricas, logs estructurados y trazas distribuidas&mdash; mediante el SDK
de OpenTelemetry, y habilitando la navegacion entre las tres a traves de un
identificador comun: el <code>trace_id</code>.</p>

<p>El objetivo no es unicamente <em>emitir</em> telemetria, sino conseguir que
las tres senales sean <strong>mutuamente navegables</strong>. Una metrica que
muestra un pico de latencia responde <em>que</em> ocurrio; la traza asociada
explica <em>donde</em>; y los logs de esa misma traza revelan <em>por que</em>.
Sin correlacion, cada senal obliga a reconstruir el contexto a mano, que es
precisamente el trabajo que consume el tiempo durante un incidente.</p>

<div class="destacado">
  <strong>Resultado principal:</strong> el pipeline queda verificado de forma
  automatizada mediante <code>scripts/verify-pipeline.sh</code>, que dispara una
  peticion real y comprueba, consultando las APIs de Jaeger, Loki y Prometheus,
  que ese mismo <code>trace_id</code> aparece en las tres senales y que la traza
  contiene spans de <em>ambos</em> microservicios.
</div>

<h2>2. Arquitectura implementada</h2>

<h3>2.1 Flujo de la aplicacion</h3>

<p>La aplicacion modela un caso de negocio deliberadamente sencillo pero
suficiente para ejercitar todos los mecanismos de observabilidad relevantes:
una dependencia HTTP entre servicios y acceso a base de datos en ambos extremos.</p>

<pre><code>cliente
  |
  v  GET /order/{{id}}
service-a (FastAPI :8000)  ---- SQL ----&gt;  PostgreSQL
  |                                           ^
  |  HTTP + header traceparent (W3C)          |
  v                                           |
service-b (FastAPI :8001)  ---- SQL ----------+</code></pre>

<p>El salto HTTP de <code>service-a</code> a <code>service-b</code> es el punto
critico: la instrumentacion de HTTPX inyecta la cabecera <code>traceparent</code>
en la peticion saliente y la de FastAPI la extrae en el servicio receptor. El
resultado es que ambos servicios producen spans bajo un <strong>unico
<code>trace_id</code></strong>, en lugar de dos trazas inconexas.</p>

<h3>2.2 Pipeline de telemetria</h3>

<pre><code>service-a / service-b
   |
   |  OTLP/gRPC :4317   (trazas + metricas + logs)
   v
OTel Collector
   |  memory_limiter -&gt; resourcedetection -&gt; resource
   |  -&gt; filter/health -&gt; attributes -&gt; batch
   |
   +--&gt; Jaeger      :16686   trazas (UI de referencia)
   +--&gt; Tempo       :3200    trazas (nativo de Grafana)
   +--&gt; Prometheus  :9090    metricas
   +--&gt; Loki        :3100    logs
              |
              v
          Grafana :3000  (correlacion por trace_id)</code></pre>

<h3>2.3 Las tres senales emitidas</h3>

<table>
  <tr><th>Senal</th><th>Mecanismo del SDK</th><th>Transporte</th><th>Backend</th></tr>
  <tr>
    <td><strong>Trazas</strong></td>
    <td>TracerProvider + BatchSpanProcessor</td>
    <td>OTLP/gRPC</td>
    <td>Jaeger, Tempo</td>
  </tr>
  <tr>
    <td><strong>Metricas</strong></td>
    <td>MeterProvider con dos readers:<br>
        PeriodicExporting (push) + Prometheus (scrape)</td>
    <td>OTLP/gRPC y HTTP :9464</td>
    <td>Prometheus</td>
  </tr>
  <tr>
    <td><strong>Logs</strong></td>
    <td>LoggerProvider + LoggingHandler,<br>
        y JSON a stdout con trace_id inyectado</td>
    <td>OTLP/gRPC</td>
    <td>Loki</td>
  </tr>
</table>

<h3>2.4 Instrumentacion aplicada</h3>

<p><strong>Automatica.</strong> Tres librerias instrumentadas sin modificar el
codigo de negocio: <code>FastAPI</code> genera un span de servidor por peticion
y extrae el contexto entrante; <code>HTTPX</code> genera spans de cliente e
inyecta el <code>traceparent</code>; <code>psycopg2</code> genera un span por
sentencia SQL con la consulta como atributo.</p>

<p><strong>Personalizada.</strong> Spans que describen la logica de negocio, no
solo la mecanica tecnica:</p>

<table>
  <tr><th>Span</th><th>Servicio</th><th>Que representa</th></tr>
  <tr><td><code>order.process</code></td><td>service-a</td>
      <td>Span raiz de la operacion de negocio completa</td></tr>
  <tr><td><code>fetch.order.db</code></td><td>service-a</td>
      <td>Recuperacion del pedido</td></tr>
  <tr><td><code>call.service-b.inventory</code></td><td>service-a</td>
      <td>Llamada downstream con propagacion de contexto</td></tr>
  <tr><td><code>order.compute_total</code></td><td>service-a</td>
      <td>Calculo del importe y decision de surtido</td></tr>
  <tr><td><code>inventory.lookup.db</code></td><td>service-b</td>
      <td>Consulta de stock</td></tr>
  <tr><td><code>inventory.validate.stock</code></td><td>service-b</td>
      <td>Regla de negocio sobre el nivel de stock</td></tr>
</table>

<div class="salto"></div>

<h2>3. Configuracion del OTel Collector</h2>

<p>El Collector actua como punto unico de entrada de las tres senales. Los
servicios no conocen ningun backend: solo exportan por OTLP. Ese desacoplamiento
permite cambiar de Jaeger a Cloud Trace sin tocar una linea de la aplicacion
&mdash; exactamente lo que ocurre entre los tres entornos del repositorio.</p>

<h3>3.1 Orden de los procesadores</h3>

<p>El orden no es arbitrario y condiciona el comportamiento bajo carga:</p>

<table>
  <tr><th>#</th><th>Procesador</th><th>Razon de su posicion</th></tr>
  <tr><td>1</td><td><code>memory_limiter</code></td>
      <td>Debe ir <strong>primero</strong>. Si se colocara despues de
      <code>batch</code>, el lote ya habria reservado la memoria que se intenta
      limitar.</td></tr>
  <tr><td>2</td><td><code>resourcedetection</code></td>
      <td>Anade metadatos del entorno antes de que otros procesadores los usen.</td></tr>
  <tr><td>3</td><td><code>resource</code></td>
      <td>Atributos comunes a las tres senales: son los que permiten filtrarlas
      por el mismo criterio en Grafana.</td></tr>
  <tr><td>4</td><td><code>filter/health</code></td>
      <td>Descarta pronto el ruido para no procesarlo ni agruparlo.</td></tr>
  <tr><td>5</td><td><code>attributes</code></td>
      <td>Control de cardinalidad: cada combinacion de labels es una serie nueva
      en Prometheus.</td></tr>
  <tr><td>6</td><td><code>batch</code></td>
      <td><strong>Ultimo</strong>, justo antes de los exporters, que es donde la
      agrupacion reduce llamadas de red.</td></tr>
</table>

<h3>3.2 Una configuracion por entorno</h3>

<table>
  <tr><th>Archivo</th><th>Entorno</th><th>Exporters</th></tr>
  <tr><td><code>collector-local.yaml</code></td><td>Docker Compose</td>
      <td>Jaeger, Tempo, Prometheus, Loki</td></tr>
  <tr><td><code>collector-gcp.yaml</code></td><td>Cloud Run (sidecar)</td>
      <td>Cloud Trace, Cloud Logging, Managed Prometheus</td></tr>
  <tr><td><code>collector-aws.yaml</code></td><td>ECS Fargate (sidecar)</td>
      <td>X-Ray, CloudWatch Logs, CloudWatch EMF</td></tr>
</table>

<p>La estructura de receivers y procesadores es <strong>identica</strong> en los
tres archivos; solo cambian los exporters. Esa simetria es intencional: permite
validar el comportamiento del pipeline en local y confiar en que la nube se
comporta igual, porque la unica variable que cambia es el destino.</p>

<div class="nota">
  <strong>Alcance de la ejecucion.</strong> El pipeline se ejecuto y verifico de
  forma completa en el entorno local con Docker Compose. La infraestructura para
  ambas nubes esta descrita como codigo en <code>terraform/</code>, parametrizada
  y versionada. El despliegue en AWS no se materializo por no disponer de una
  cuenta; su Terraform se entrega completo pero sin aplicar.
</div>

<h2>4. Correlacion cross-signal</h2>

<p>La correlacion se configura de forma declarativa en el aprovisionamiento de
datasources de Grafana, y esta habilitada en <strong>ambos sentidos</strong>:</p>

<table>
  <tr><th>Salto</th><th>Mecanismo</th><th>Datasource</th></tr>
  <tr><td>Log &rarr; Traza</td><td><code>derivedFields</code> sobre el trace_id</td><td>Loki</td></tr>
  <tr><td>Traza &rarr; Log</td><td><code>tracesToLogsV2</code> con consulta LogQL</td><td>Jaeger, Tempo</td></tr>
  <tr><td>Traza &rarr; Metrica</td><td><code>tracesToMetrics</code></td><td>Jaeger, Tempo</td></tr>
  <tr><td>Metrica &rarr; Traza</td><td><code>exemplarTraceIdDestinations</code></td><td>Prometheus</td></tr>
</table>

<h3>4.1 El trace_id como pivote</h3>

<p>Para que el salto funcione, el mismo identificador debe estar presente en las
tres senales con el mismo formato. En las <strong>trazas</strong> es intrinseco.
En los <strong>logs</strong> se inyecta mediante un formateador JSON que lee el
span activo en cada registro. En las <strong>metricas</strong> la union no es por
<code>trace_id</code> &mdash;seria una explosion de cardinalidad inaceptable&mdash;
sino por los atributos de Resource compartidos, mas los <em>exemplars</em>, que
enlazan muestras concretas del histograma con la traza que las produjo.</p>

<pre><code>{{
  "message": "Pedido procesado",
  "order_id": "ORD-0001",
  "trace_id": "d236b3bd43faec1e0e8698df474610c6",
  "span_id":  "06ef8d52c9e6daba",
  "service":  "service-a",
  "level":    "info"
}}</code></pre>

<h3>4.2 Verificacion de la propagacion W3C</h3>

<p>La comprobacion decisiva no es que exista un <code>trace_id</code>, sino que
<strong>sea el mismo a ambos lados del salto HTTP</strong>. El script de
verificacion consulta la API de Jaeger y confirma que la traza contiene procesos
de <code>service-a</code> y de <code>service-b</code>: si la propagacion
fallara, <code>service-b</code> iniciaria una traza independiente y solo
aparecerian spans de un servicio.</p>

{correlacion}

<div class="salto"></div>

<h2>5. Analisis de overhead</h2>

<h3>5.1 Metodologia</h3>

<p>La comparacion se realiza entre dos despliegues que ejecutan
<strong>la misma imagen y el mismo codigo</strong>. La unica diferencia es la
variable de entorno <code>OTEL_ENABLED</code>: cuando vale <code>false</code>,
el modulo de telemetria devuelve implementaciones vacias y los imports del SDK
&mdash;diferidos a proposito&mdash; nunca llegan a ejecutarse.</p>

<p>Un benchmark con dos bases de codigo separadas no mediria solo el costo de
OpenTelemetry, sino tambien las diferencias accidentales entre ambas
implementaciones. Ambos despliegues reciben ademas limites de recursos
identicos (1.0 CPU / 512 MiB); sin esa igualdad, una diferencia de CPU
disponible se confundiria con el costo de la instrumentacion.</p>

<p>Las metricas provienen de <strong>dos fuentes independientes</strong>, para no
pedirle al proceso instrumentado que se mida a si mismo:</p>

<ul>
  <li><strong>Latencia y throughput</strong> &mdash; medidos por k6 desde el
      cliente, fuera del proceso observado.</li>
  <li><strong>CPU y memoria</strong> &mdash; medidos por el receiver
      <code>docker_stats</code> del Collector, que lee las estadisticas del
      demonio de Docker desde el host.</li>
</ul>

<h3>5.2 Dos regimenes de carga</h3>

<p>La medicion se repitio bajo dos niveles de concurrencia porque responden a
preguntas distintas y una sola de ellas daria una imagen incompleta:</p>

<ul>
  <li><strong>Carga moderada (25 VUs).</strong> La CPU no esta topada, de modo
      que el consumo adicional del SDK es directamente observable. Responde
      <em>cuanto cuesta instrumentar</em>.</li>
  <li><strong>Saturacion (75 VUs).</strong> Ambos escenarios agotan el limite de
      1.0 CPU por contenedor. Al no quedar CPU libre, el costo de la telemetria
      no puede manifestarse como mas consumo y se traduce en menos peticiones
      atendidas. Responde <em>cuanta capacidad cuesta</em>.</li>
</ul>

<div class="nota">
  Reportar unicamente el escenario saturado habria sido enganoso: la CPU
  aparece casi igual en ambos casos (~100 %) no porque la instrumentacion sea
  gratuita, sino porque <strong>no hay mas CPU que consumir</strong>. El limite
  del contenedor actua como techo y enmascara el costo real.
</div>

<h3>5.3 Resultados</h3>

{resultados}

<h3>5.4 Interpretacion</h3>

<p>El costo de la instrumentacion se reparte de forma desigual entre las tres
dimensiones medidas, y conviene leer cada una con un criterio distinto:</p>

<p><strong>Latencia.</strong> El camino critico de la peticion solo paga la
creacion de spans en memoria y la escritura en la cola del
<code>BatchSpanProcessor</code>. La exportacion por red ocurre en un hilo
independiente, por lo que no bloquea la respuesta. El percentil p99 es el
indicador mas informativo: la media puede esconder el costo real, mientras que
la cola lenta revela el efecto de los vaciados periodicos del lote.</p>

<p><strong>CPU.</strong> Es donde se concentra el gasto: serializar spans a
Protobuf, agregar histogramas y formatear registros consume ciclos de forma
proporcional al volumen de telemetria, no al numero de peticiones. El efecto
solo es legible en el regimen no saturado; bajo saturacion queda oculto tras el
techo del contenedor.</p>

<p><strong>Memoria.</strong> El SDK introduce un costo <em>base fijo</em>
&mdash;providers, exporters y buffers de los procesadores por lotes&mdash; que se
paga al arrancar y que luego crece poco con la carga. En servicios pequenos este
costo fijo puede representar un porcentaje llamativo sin ser preocupante en
terminos absolutos.</p>

<p><strong>Throughput.</strong> Es la traduccion practica del overhead cuando el
servicio ya opera al limite. Cada ciclo de CPU dedicado a producir telemetria es
un ciclo que no atiende peticiones, de modo que la capacidad maxima baja aunque
el consumo medido se mantenga igual.</p>

<div class="nota">
  <strong>Sobre el lenguaje de la aplicacion.</strong> Los servicios estan
  escritos en Python, donde el bloqueo global del interprete impide que el hilo
  de exportacion y el de atencion de peticiones progresen en paralelo dentro del
  mismo proceso. El overhead relativo medido aqui es, por tanto, un limite
  superior: una implementacion equivalente en Go o Java mostraria un costo
  menor con la misma configuracion de OpenTelemetry.
</div>

<div class="destacado">
  <strong>Palancas para reducir el overhead en produccion.</strong>
  <ul style="margin-bottom:0">
    <li><strong>Muestreo.</strong> Exportar el 100 % de las trazas es adecuado
        para un laboratorio, donde cada traza es evidencia. En produccion,
        <code>tail_sampling</code> permite conservar siempre los errores y las
        peticiones lentas, y muestrear solo el trafico exitoso rutinario.</li>
    <li><strong>Cardinalidad de metricas.</strong> Cada combinacion distinta de
        labels crea una serie temporal nueva. El procesador
        <code>attributes</code> elimina los atributos que no aportan valor
        analitico.</li>
    <li><strong>Filtrado temprano.</strong> Descartar los health checks evita
        procesar y almacenar un volumen alto de trazas sin informacion de
        negocio.</li>
    <li><strong>Tamano del lote.</strong> Lotes mayores reducen las llamadas de
        red a costa de mas memoria retenida; es un intercambio que se ajusta
        segun el perfil del servicio.</li>
  </ul>
</div>

<h2>6. Decisiones de diseno</h2>

<h3>6.1 Dos readers de metricas</h3>

<p>Las metricas salen por dos caminos simultaneos: <em>push</em> OTLP hacia el
Collector &mdash;el camino de produccion&mdash; y un endpoint
<code>/metrics</code> local para scraping directo. El segundo actua como control:
permite comprobar que el Collector no pierde ni altera metricas en el trayecto.
El efecto secundario es que cada serie aparece duplicada en Prometheus,
distinguida por el label <code>source</code>; todas las consultas del dashboard
filtran por <code>source="collector"</code>, sin lo cual el throughput se
contaria dos veces.</p>

<h3>6.2 Fronteras explicitas en los histogramas</h3>

<p>Los buckets por defecto del SDK (<code>[0, 5, 10, 25, ... 10000]</code>) estan
pensados para valores en milisegundos. Este laboratorio registra la latencia en
segundos, siguiendo la convencion de Prometheus, de modo que practicamente todas
las muestras caian en el primer bucket <code>[0, 5)</code> y
<code>histogram_quantile</code> devolvia un p99 proximo a 5 s con independencia
de la latencia real. Se definieron vistas con las fronteras estandar de latencia
HTTP, lo que corrigio el calculo: el p99 observado paso de un valor artificial
cercano a 5 s a decenas de milisegundos.</p>

<div class="nota">
  Este fallo es un buen ejemplo de un riesgo caracteristico de la
  observabilidad: un panel que <em>parece</em> funcionar y muestra numeros
  plausibles puede estar midiendo mal. La deteccion no vino del dashboard, sino
  de contrastar el valor agregado con la latencia real observada en las trazas.
</div>

<h3>6.3 Pool de conexiones a base de datos</h3>

<p>Sin un pool, cada peticion pagaria el handshake TCP y la autenticacion de
PostgreSQL. Ese costo dominaria la medicion y se le atribuiria a OpenTelemetry
una latencia que en realidad corresponde a la base de datos.</p>

<h3>6.4 Jaeger y Tempo en paralelo</h3>

<p>Jaeger aporta la interfaz de referencia del entregable. Tempo se integra de
forma nativa con Grafana y su <code>metrics_generator</code> deriva metricas RED
y el mapa de servicios a partir de las propias trazas, anadiendo una via
adicional de correlacion entre trazas y metricas.</p>

<h2>7. Reproducibilidad</h2>

<pre><code># 1. Levantar el stack completo
docker compose up -d --build

# 2. Verificar la correlacion de las tres senales
bash scripts/verify-pipeline.sh

# 3. Ejecutar el benchmark comparativo
bash scripts/run-benchmark.sh

# 4. Regenerar este reporte con los resultados obtenidos
python docs/generar_reporte.py &amp;&amp; bash scripts/generar-pdf.sh</code></pre>

<p>Toda la configuracion esta versionada: dashboards como JSON, datasources como
YAML de aprovisionamiento, infraestructura como codigo Terraform y dependencias
con version fijada. No hay ningun paso manual en la interfaz de Grafana que
haya que repetir para reconstruir el entorno.</p>

<h2>8. Conclusiones</h2>

<p>El pipeline cumple el objetivo planteado: las tres senales se emiten desde los
microservicios, se centralizan en un unico Collector y resultan mutuamente
navegables a traves del <code>trace_id</code>. La propagacion de contexto W3C
entre servicios quedo verificada de forma automatizada, no solo observada en la
interfaz.</p>

<p>Dos aprendizajes destacan por encima de la mecanica de configuracion. El
primero es que <strong>la correlacion es una decision de diseno, no una
consecuencia automatica</strong> de instrumentar: exige que el identificador
viaje en las tres senales con un formato consistente y que las herramientas sepan
como saltar entre ellas. El segundo es que <strong>la telemetria tambien hay que
verificarla</strong>: el error en los buckets del histograma producia percentiles
plausibles pero incorrectos, y un dashboard equivocado durante un incidente es
peor que no tener dashboard, porque dirige la investigacion en la direccion
equivocada.</p>

<p>Respecto al overhead, la conclusion practica es que el costo se concentra en
CPU y en un consumo base fijo de memoria, mientras que el impacto en la latencia
percibida por el usuario se mantiene acotado gracias a la exportacion asincrona
por lotes. Ese costo es ajustable mediante muestreo y control de cardinalidad,
lo que convierte la decision en un intercambio explicito entre profundidad de
observabilidad y consumo de recursos, en lugar de un precio fijo que haya que
aceptar sin mas.</p>

</body>
</html>
"""


if __name__ == "__main__":
    sys.exit(generar())
