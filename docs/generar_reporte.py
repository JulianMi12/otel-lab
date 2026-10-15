#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
generar_reporte.py - Construye el reporte tecnico del laboratorio.

Lee los resultados REALES del benchmark y genera docs/reporte-tecnico.html,
listo para convertir a PDF con scripts/generar-pdf.sh.

Que las cifras se inyecten desde el JSON de la medicion, en lugar de
transcribirse a mano, evita que el reporte y la evidencia se desincronicen.

Uso:
    python docs/generar_reporte.py
    bash scripts/generar-pdf.sh
"""

import json
import os
import sys
from datetime import datetime

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTADOS = os.path.join(RAIZ, "benchmark", "results")
SALIDA_HTML = os.path.join(RAIZ, "docs", "reporte-tecnico.html")

# Tres regimenes de carga: el overhead no desaparece ni crece, cambia de forma
# segun quede o no CPU libre.
REGIMENES = [
    {"carpeta": "ligera-10vus", "etiqueta": "10 VUs", "nota": "holgado"},
    {"carpeta": "moderada-25vus", "etiqueta": "25 VUs", "nota": "apretado"},
    {"carpeta": "saturacion-75vus", "etiqueta": "75 VUs", "nota": "saturado"},
]

FILAS = [
    ("Latencia media", "Latencia media"),
    ("Latencia p95", "Latencia p95"),
    ("Latencia p99", "Latencia p99"),
    ("Throughput", "Throughput"),
    ("CPU media de los servicios", "CPU media"),
    ("CPU del OTel Collector", "CPU Collector"),
    ("Memoria pico de los servicios", "Memoria pico"),
]


def cargar(nombre, subcarpeta):
    ruta = os.path.join(RESULTADOS, subcarpeta, nombre)
    if not os.path.exists(ruta):
        return None
    try:
        with open(ruta, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as exc:
        print("  [aviso] no se pudo leer %s: %s" % (nombre, exc))
        return None


def cargar_regimenes():
    disponibles = []
    for reg in REGIMENES:
        overhead = cargar("overhead.json", reg["carpeta"])
        instr = cargar("k6-instrumented.json", reg["carpeta"])
        base = cargar("k6-baseline.json", reg["carpeta"])
        if overhead and instr and base:
            disponibles.append(dict(reg, overhead=overhead, instr=instr, base=base))
            print("  %s: encontrado" % reg["carpeta"])
        else:
            print("  %s: sin datos" % reg["carpeta"])
    return disponibles


def valor(overhead, metrica, campo):
    for f in overhead.get("tabla", []):
        if f["metrica"] == metrica:
            return f.get(campo, "n/d")
    return "n/d"


def clase_overhead(texto):
    """Resalta en rojo el overhead alto y en verde las mejoras."""
    try:
        v = float(texto.replace("%", "").replace("+", "").strip())
        if v > 15:
            return ' class="alto"'
        if v < 0:
            return ' class="mejora"'
    except (ValueError, AttributeError):
        pass
    return ""


def cabecera_comparativa(regimenes):
    sup = ['<tr><th rowspan="2">Metrica</th>']
    inf = ["<tr>"]
    for reg in regimenes:
        sup.append('<th colspan="3">%s</th>' % reg["etiqueta"])
        inf.append("<th>sin</th><th>con</th><th>&Delta;</th>")
    sup.append("</tr>")
    inf.append("</tr>")
    return "".join(sup) + "".join(inf)


def tabla_comparativa(regimenes):
    """Una sola tabla con los tres regimenes en columnas."""
    if not regimenes:
        return '<tr><td colspan="10" class="sin-datos">Benchmark no ejecutado.</td></tr>'

    filas = []
    for metrica, etiqueta in FILAS:
        celdas = ["<td><strong>%s</strong></td>" % etiqueta]
        for reg in regimenes:
            o = reg["overhead"]
            delta = valor(o, metrica, "delta_pct")
            celdas.append(
                '<td class="num">%s</td><td class="num">%s</td><td class="num"%s>%s</td>'
                % (
                    valor(o, metrica, "base"),
                    valor(o, metrica, "instrumentado"),
                    clase_overhead(delta),
                    delta,
                )
            )
        filas.append("<tr>" + "".join(celdas) + "</tr>")
    return "\n".join(filas)


def sintesis(regimenes):
    """Resume el hallazgo central: el overhead cambia de forma."""
    if not regimenes:
        return ""
    filas = []
    for reg in regimenes:
        o = reg["overhead"]
        d_cpu = valor(o, "CPU media de los servicios", "delta_pct")
        filas.append(
            '<tr><td><strong>%s</strong> &mdash; %s</td>'
            '<td class="num">%s</td><td class="num"%s>%s</td>'
            '<td class="num">%s</td><td class="num">%s</td></tr>'
            % (
                reg["etiqueta"],
                reg["nota"],
                valor(o, "CPU media de los servicios", "base"),
                clase_overhead(d_cpu),
                d_cpu,
                valor(o, "Throughput", "delta_pct"),
                valor(o, "Memoria pico de los servicios", "delta_pct"),
            )
        )
    return "\n".join(filas)


def condiciones(regimenes):
    if not regimenes:
        return ""
    total = sum(int(r["instr"].get("requests_totales") or 0) for r in regimenes)
    total += sum(int(r["base"].get("requests_totales") or 0) for r in regimenes)
    trazas = sum(int(r["instr"].get("respuestas_con_trace_id") or 0) for r in regimenes)
    fmt = lambda n: "{:,}".format(n).replace(",", ".")
    return (
        "<p><strong>Condiciones:</strong> seis corridas (tres regimenes &times; "
        "dos escenarios), <strong>%s peticiones</strong> en total, limites "
        "identicos de 1.0 CPU y 512 MiB por contenedor, y una mezcla de trafico "
        "de 85&nbsp;%% consultas de pedido, 10&nbsp;%% listados y 5&nbsp;%% "
        "pedidos inexistentes. <strong>%s respuestas</strong> incluyeron un "
        "<code>trace_id</code> W3C valido de 32 digitos hexadecimales.</p>"
        % (fmt(total), fmt(trazas))
    )


def generar():
    print("Leyendo resultados del benchmark...")
    regimenes = cargar_regimenes()

    html = PLANTILLA.format(
        fecha=datetime.now().strftime("%d/%m/%Y"),
        cabecera_comp=cabecera_comparativa(regimenes),
        tabla_comp=tabla_comparativa(regimenes),
        sintesis=sintesis(regimenes),
        condiciones=condiciones(regimenes),
    )

    with open(SALIDA_HTML, "w", encoding="utf-8") as fh:
        fh.write(html)

    print("\nReporte generado: %s" % SALIDA_HTML)
    print("Para el PDF:  bash scripts/generar-pdf.sh")
    return 0


PLANTILLA = u"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<title>Reporte Tecnico - Pipeline de Observabilidad con OpenTelemetry</title>
<style>
  @page {{ size: A4; margin: 13mm 12mm 14mm 12mm; }}

  :root {{
    --tinta:  #1a2332;
    --suave:  #5a6778;
    --acento: #1c3d5a;
    --linea:  #d4dae2;
    --fondo:  #f6f8fa;
    --alerta: #b4453c;
    --ok:     #2d7d4f;
  }}

  * {{ box-sizing: border-box; }}

  body {{
    font-family: "Segoe UI", -apple-system, system-ui, sans-serif;
    font-size: 8.4pt;
    line-height: 1.38;
    color: var(--tinta);
    margin: 0 auto;
    max-width: 186mm;
    padding: 5mm;
    background: #fff;
  }}

  h1 {{ font-size: 15.5pt; line-height: 1.14; margin: 0 0 3px;
       color: var(--acento); letter-spacing: -.3px; }}
  h2 {{ font-size: 10.2pt; margin: 11px 0 5px; padding-bottom: 2px;
       border-bottom: 1.4px solid var(--acento); color: var(--acento);
       page-break-after: avoid; }}
  h3 {{ font-size: 8.8pt; margin: 8px 0 3px; page-break-after: avoid; }}

  p {{ margin: 0 0 5px; text-align: justify; }}
  ul {{ margin: 0 0 5px; padding-left: 14px; }}
  li {{ margin-bottom: 2px; }}

  code {{ font-family: "Cascadia Mono", Consolas, monospace; font-size: 7.4pt;
          background: var(--fondo); padding: 0 2px; border-radius: 2px; }}

  pre {{ font-family: "Cascadia Mono", Consolas, monospace; font-size: 6.6pt;
         line-height: 1.28; background: var(--fondo);
         border: .5px solid var(--linea); border-left: 2px solid var(--acento);
         border-radius: 3px; padding: 5px 7px; overflow-x: auto;
         page-break-inside: avoid; margin: 0 0 6px; white-space: pre; }}
  pre code {{ background: none; padding: 0; font-size: inherit; }}

  table {{ width: 100%; border-collapse: collapse; margin: 0 0 7px;
           font-size: 7.1pt; page-break-inside: avoid; }}
  th {{ background: var(--acento); color: #fff; text-align: left;
        padding: 2.5px 4px; font-weight: 600; }}
  td {{ padding: 2px 4px; border-bottom: .5px solid var(--linea); }}
  tr:nth-child(even) td {{ background: #fafbfc; }}
  td.alto {{ color: var(--alerta); font-weight: 700; }}
  td.mejora {{ color: var(--ok); font-weight: 700; }}
  .num {{ text-align: right; font-variant-numeric: tabular-nums;
          white-space: nowrap; }}

  .portada {{ border-bottom: 2.5px solid var(--acento); padding-bottom: 7px;
              margin-bottom: 9px; }}
  .sub {{ font-size: 9pt; color: var(--suave); margin: 2px 0 6px; }}
  .meta {{ font-size: 7.5pt; color: var(--suave); line-height: 1.5; }}
  .meta strong {{ color: var(--tinta); }}

  .nota {{ background: #fdf6e3; border-left: 2px solid #c89b3c;
           padding: 4px 7px; margin: 6px 0; font-size: 7.5pt;
           page-break-inside: avoid; }}
  .dest {{ background: var(--fondo); border-left: 2px solid var(--acento);
           padding: 4px 7px; margin: 6px 0; page-break-inside: avoid;
           font-size: 7.9pt; }}
  .sin-datos {{ color: var(--suave); font-style: italic; }}

  .cols {{ display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }}

  /* Evidencias en rejilla: nueve capturas sin ocupar nueve paginas */
  .ev-grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 6px; }}
  .ev {{ page-break-inside: avoid; }}
  .ev img {{ width: 100%; height: auto; border: .5px solid var(--linea);
             border-radius: 2px; display: block; }}
  .ev .pie {{ font-size: 6.5pt; color: var(--suave); margin-top: 2px;
              line-height: 1.3; }}
  .ev .pie strong {{ color: var(--tinta); }}
  .et {{ display: inline-block; font-size: 5.8pt; font-weight: 700;
         padding: 0 3px; border-radius: 2px; margin-right: 2px; }}
  .et-l {{ background: #e3edf7; color: #1c3d5a; }}
  .et-g {{ background: #e6f0e8; color: #2d5c3d; }}
  .ancho {{ grid-column: 1 / -1; }}
</style>
</head>
<body>

<div class="portada">
  <h1>Pipeline de Observabilidad End-to-End con OpenTelemetry</h1>
  <div class="sub">Instrumentaci&oacute;n de microservicios, correlaci&oacute;n cross-signal y an&aacute;lisis de overhead</div>
  <div class="meta">
    <strong>Programa:</strong> Maestr&iacute;a en Arquitectura de Software &mdash; Universidad de La Sabana
    &nbsp;&middot;&nbsp; <strong>Asignatura:</strong> Observabilidad en Ambientes Productivos
    &nbsp;&middot;&nbsp; <strong>Fecha:</strong> {fecha}<br>
    <strong>Integrantes:</strong> Edgar Andr&eacute;s Romero Ot&aacute;lora &nbsp;&middot;&nbsp;
    Jhon Alexander Tenjo Romero &nbsp;&middot;&nbsp; Juli&aacute;n David Miranda Leguizam&oacute;n
  </div>
</div>

<h2>1. Objetivo y resultado</h2>

<p>Se implementa un pipeline de observabilidad completo sobre una aplicaci&oacute;n de
microservicios, capturando las tres se&ntilde;ales &mdash;m&eacute;tricas, logs estructurados y
trazas distribuidas&mdash; con el SDK de OpenTelemetry, y habilitando la
navegaci&oacute;n entre ellas a trav&eacute;s de un identificador com&uacute;n: el <code>trace_id</code>.</p>

<p>El objetivo no es s&oacute;lo <em>emitir</em> telemetr&iacute;a, sino que las tres se&ntilde;ales sean
<strong>mutuamente navegables</strong>. Una m&eacute;trica que muestra un pico de latencia
responde <em>qu&eacute;</em> ocurri&oacute;; la traza asociada explica <em>d&oacute;nde</em>; y los logs de
esa traza, <em>por qu&eacute;</em>. Sin correlaci&oacute;n, cada se&ntilde;al obliga a reconstruir el
contexto a mano, que es justo lo que consume el tiempo durante un incidente.</p>

<div class="dest">
  <strong>Resultado.</strong> El pipeline se verifica de forma automatizada con
  <code>scripts/verify-pipeline.sh</code>, que dispara una petici&oacute;n real y
  comprueba, consultando las APIs de Jaeger, Loki y Prometheus, que ese mismo
  <code>trace_id</code> aparece en las tres se&ntilde;ales y que la traza contiene spans
  de <em>ambos</em> microservicios: <strong>18 de 18 comprobaciones</strong>. El
  despliegue se realiz&oacute; en local (Docker Compose) y en <strong>GCP Cloud Run</strong>,
  con el Collector como contenedor sidecar.
</div>

<h2>2. Arquitectura</h2>

<div class="cols">
<div>
<pre><code>cliente
  &#9474; GET /order/{{id}}
  &#9660;
service-a (FastAPI :8000) &#9472;&#9472;SQL&#9472;&#9658; PostgreSQL
  &#9474;                                 &#9650;
  &#9474; HTTP + traceparent (W3C)        &#9474;
  &#9660;                                 &#9474;
service-b (FastAPI :8001) &#9472;&#9472;SQL&#9472;&#9472;&#9472;&#9472;&#9496;</code></pre>
</div>
<div>
<pre><code>service-a / service-b
  &#9474; OTLP/gRPC :4317
  &#9660;
OTel Collector
  memory_limiter &#8594; resourcedetection
  &#8594; resource &#8594; filter &#8594; batch
  &#9500;&#9472;&#9658; Jaeger :16686   trazas
  &#9500;&#9472;&#9658; Tempo  :3200    trazas
  &#9500;&#9472;&#9658; Prometheus      m&eacute;tricas
  &#9492;&#9472;&#9658; Loki   :3100    logs
          &#9660;
      Grafana :3000</code></pre>
</div>
</div>

<p>El salto HTTP de <code>service-a</code> a <code>service-b</code> es el punto
cr&iacute;tico: la instrumentaci&oacute;n de HTTPX inyecta la cabecera <code>traceparent</code> y
la de FastAPI la extrae en el receptor, por lo que ambos servicios producen spans
bajo un <strong>&uacute;nico <code>trace_id</code></strong> en vez de dos trazas inconexas.</p>

<table>
  <tr><th>Se&ntilde;al</th><th>Mecanismo del SDK</th><th>Transporte</th><th>Backend local</th><th>Backend GCP</th></tr>
  <tr><td><strong>Trazas</strong></td><td>TracerProvider + BatchSpanProcessor</td><td>OTLP/gRPC</td><td>Jaeger, Tempo</td><td>Cloud Trace</td></tr>
  <tr><td><strong>M&eacute;tricas</strong></td><td>MeterProvider con dos readers: PeriodicExporting (push) + Prometheus (scrape)</td><td>OTLP/gRPC &middot; HTTP :9464</td><td>Prometheus</td><td>Managed Prometheus</td></tr>
  <tr><td><strong>Logs</strong></td><td>LoggerProvider + LoggingHandler, y JSON a stdout con trace_id inyectado</td><td>OTLP/gRPC</td><td>Loki</td><td>Cloud Logging</td></tr>
</table>

<p><strong>Instrumentaci&oacute;n autom&aacute;tica:</strong> FastAPI (spans de servidor y
extracci&oacute;n de contexto), HTTPX (spans de cliente e inyecci&oacute;n del
<code>traceparent</code>) y psycopg2 (un span por sentencia SQL).
<strong>Custom spans de negocio:</strong> <code>order.process</code>,
<code>fetch.order.db</code>, <code>call.service-b.inventory</code>,
<code>order.compute_total</code>, <code>inventory.lookup.db</code> e
<code>inventory.validate.stock</code>.</p>

<h2>3. OTel Collector</h2>

<p>El Collector es el punto &uacute;nico de entrada de las tres se&ntilde;ales. Los servicios no
conocen ning&uacute;n backend: s&oacute;lo exportan por OTLP. Ese desacoplamiento permite cambiar
de Jaeger a Cloud Trace sin tocar una l&iacute;nea de la aplicaci&oacute;n, que es exactamente lo
que ocurre entre los tres entornos del repositorio
(<code>collector-local.yaml</code>, <code>collector-gcp.yaml</code>,
<code>collector-aws.yaml</code>). La estructura de receivers y procesadores es
id&eacute;ntica en los tres; s&oacute;lo cambian los exporters.</p>

<table>
  <tr><th>#</th><th>Procesador</th><th>Raz&oacute;n de su posici&oacute;n en el pipeline</th></tr>
  <tr><td>1</td><td><code>memory_limiter</code></td><td>Debe ir <strong>primero</strong>: situado tras <code>batch</code>, el lote ya habr&iacute;a reservado la memoria que se intenta limitar</td></tr>
  <tr><td>2</td><td><code>resourcedetection</code></td><td>A&ntilde;ade metadatos del entorno antes de que otros procesadores los usen</td></tr>
  <tr><td>3</td><td><code>resource</code></td><td>Atributos comunes a las tres se&ntilde;ales: permiten filtrarlas por el mismo criterio</td></tr>
  <tr><td>4</td><td><code>filter/health</code></td><td>Descarta pronto los sondeos de liveness, que dominar&iacute;an el volumen sin aportar negocio</td></tr>
  <tr><td>5</td><td><code>attributes</code></td><td>Control de cardinalidad: cada combinaci&oacute;n de labels es una serie nueva en Prometheus</td></tr>
  <tr><td>6</td><td><code>batch</code></td><td><strong>&Uacute;ltimo</strong>, junto a los exporters, que es donde agrupar reduce llamadas de red</td></tr>
</table>

<h2>4. Correlaci&oacute;n cross-signal</h2>

<div class="cols">
<div>
<table>
  <tr><th>Salto</th><th>Mecanismo</th></tr>
  <tr><td>Log &rarr; Traza</td><td><code>derivedFields</code> sobre el trace_id</td></tr>
  <tr><td>Traza &rarr; Log</td><td><code>tracesToLogsV2</code> con LogQL</td></tr>
  <tr><td>Traza &rarr; M&eacute;trica</td><td><code>tracesToMetrics</code></td></tr>
  <tr><td>M&eacute;trica &rarr; Traza</td><td><code>exemplarTraceIdDestinations</code></td></tr>
</table>
</div>
<div>
<pre><code>{{
  "message": "Pedido procesado",
  "order_id": "ORD-0001",
  "trace_id": "d236b3bd43faec1e&hellip;",
  "span_id":  "06ef8d52c9e6daba",
  "service":  "service-a",
  "level":    "info"
}}</code></pre>
</div>
</div>

<p>En las <strong>trazas</strong> el identificador es intr&iacute;nseco. En los
<strong>logs</strong> se inyecta con un formateador JSON que lee el span activo en
cada registro. En las <strong>m&eacute;tricas</strong> la uni&oacute;n no se hace por
<code>trace_id</code> &mdash;ser&iacute;a una explosi&oacute;n de cardinalidad inaceptable&mdash;
sino por los atributos de Resource compartidos, m&aacute;s los <em>exemplars</em>, que
enlazan muestras del histograma con la traza que las produjo.</p>

<p>La comprobaci&oacute;n decisiva no es que exista un <code>trace_id</code>, sino que
<strong>sea el mismo a ambos lados del salto HTTP</strong>. El script de
verificaci&oacute;n consulta la API de Jaeger y confirma que la traza contiene procesos de
<code>service-a</code> y de <code>service-b</code>: si la propagaci&oacute;n fallara, el
servicio receptor iniciar&iacute;a una traza independiente.</p>

<h2>5. An&aacute;lisis de overhead</h2>

<p>La comparaci&oacute;n se realiza entre dos despliegues que ejecutan <strong>la misma
imagen y el mismo c&oacute;digo</strong>; la &uacute;nica diferencia es la variable
<code>OTEL_ENABLED</code>, que al desactivarse devuelve implementaciones vac&iacute;as y
evita incluso cargar el SDK en memoria. Un benchmark con dos bases de c&oacute;digo
separadas no medir&iacute;a el costo de OpenTelemetry, sino las diferencias accidentales
entre ambas. Las cifras provienen de <strong>dos fuentes independientes</strong>,
para no pedirle al proceso instrumentado que se mida a s&iacute; mismo: la latencia y el
throughput los mide k6 desde el cliente; la CPU y la memoria, el receiver
<code>docker_stats</code> del Collector desde el host.</p>

{condiciones}

<h3>5.1 El overhead cambia de forma seg&uacute;n la CPU disponible</h3>

<table>
  <tr><th>R&eacute;gimen</th><th class="num">CPU en l&iacute;nea base</th><th class="num">Overhead en CPU</th><th class="num">P&eacute;rdida de throughput</th><th class="num">Memoria</th></tr>
  {sintesis}
</table>

<p>La relaci&oacute;n entre las dos columnas centrales es <strong>inversa</strong>: conforme
la CPU se agota, el overhead medido en consumo se desvanece y reaparece como
p&eacute;rdida de capacidad. Es el mismo trabajo adicional manifest&aacute;ndose all&iacute; donde queda
margen para que se note. La memoria, en cambio, sube de forma estable con
independencia de la carga, lo que confirma que es un <strong>costo fijo</strong> del
SDK &mdash;providers, exporters y buffers&mdash; y no proporcional al tr&aacute;fico.</p>

<div class="nota">
  <strong>Por qu&eacute; importa.</strong> Reportar s&oacute;lo el escenario saturado llevar&iacute;a a
  concluir que instrumentar cuesta un 2&nbsp;% de CPU. Es falso: la CPU aparece casi
  igual con y sin OTel no porque la telemetr&iacute;a sea gratuita, sino porque
  <strong>no hay m&aacute;s CPU que consumir</strong>. El l&iacute;mite del contenedor act&uacute;a como
  techo y enmascara el costo, que se cobra en el throughput.
</div>

<h3>5.2 Tabla comparativa completa</h3>

<table>
  {cabecera_comp}
  {tabla_comp}
</table>

<p><strong>Lectura por dimensi&oacute;n.</strong> La <em>latencia</em> s&oacute;lo paga, en el camino
cr&iacute;tico, la creaci&oacute;n de spans en memoria y la escritura en la cola del
<code>BatchSpanProcessor</code>; la exportaci&oacute;n ocurre en un hilo aparte. La
<em>CPU</em> concentra el gasto real: serializar a Protobuf, agregar histogramas y
formatear registros consume ciclos proporcionales al volumen de telemetr&iacute;a, no al
n&uacute;mero de peticiones. El <em>throughput</em> es la traducci&oacute;n pr&aacute;ctica del overhead
cuando el servicio ya opera al l&iacute;mite.</p>

<div class="nota">
  <strong>Sobre el lenguaje.</strong> Los servicios est&aacute;n escritos en Python, donde
  el bloqueo global del int&eacute;rprete impide que el hilo de exportaci&oacute;n y el de atenci&oacute;n
  de peticiones progresen en paralelo. El overhead relativo medido aqu&iacute; es, por
  tanto, un <strong>l&iacute;mite superior</strong>: una implementaci&oacute;n equivalente en Go o
  Java mostrar&iacute;a un costo menor con la misma configuraci&oacute;n.
</div>

<p><strong>Palancas para reducirlo en producci&oacute;n:</strong> muestreo con
<code>tail_sampling</code> conservando siempre errores y peticiones lentas; control
de cardinalidad eliminando atributos sin valor anal&iacute;tico; filtrado temprano de
health checks; y ajuste del tama&ntilde;o de lote, que intercambia llamadas de red por
memoria retenida.</p>

<h2>6. Decisiones de dise&ntilde;o</h2>

<ul>
  <li><strong>Dos readers de m&eacute;tricas.</strong> El push OTLP al Collector es el camino
  de producci&oacute;n; el endpoint <code>/metrics</code> local act&uacute;a como control para
  verificar que el Collector no pierde ni altera m&eacute;tricas. Esto duplica cada serie en
  Prometheus, distinguidas por el label <code>source</code>: todas las consultas del
  dashboard filtran <code>source="collector"</code>, sin lo cual el throughput se
  contar&iacute;a dos veces.</li>

  <li><strong>Fronteras expl&iacute;citas en los histogramas.</strong> Los buckets por defecto
  del SDK (<code>[0, 5, 10, &hellip; 10000]</code>) asumen milisegundos. Este laboratorio
  registra en segundos, siguiendo la convenci&oacute;n de Prometheus, de modo que casi todas
  las muestras ca&iacute;an en el primer bucket y <code>histogram_quantile</code> devolv&iacute;a un
  p99 cercano a 5&nbsp;s con independencia de la latencia real. Corregirlo llev&oacute; el p99
  observado de un valor artificial a decenas de milisegundos.</li>

  <li><strong>Pool de conexiones.</strong> Sin &eacute;l, cada petici&oacute;n pagar&iacute;a el handshake TCP
  y la autenticaci&oacute;n de PostgreSQL; ese costo dominar&iacute;a la medici&oacute;n y se le atribuir&iacute;a a
  OpenTelemetry una latencia que es de la base de datos.</li>

  <li><strong>Jaeger y Tempo en paralelo.</strong> Jaeger aporta la interfaz de
  referencia; Tempo se integra de forma nativa con Grafana y su
  <code>metrics_generator</code> deriva m&eacute;tricas RED y el mapa de servicios a partir de
  las propias trazas.</li>

  <li><strong>Almac&eacute;n de datos intercambiable.</strong> El despliegue en la nube se hace
  sin base de datos gestionada, por ser el &uacute;nico recurso con costo por hora continuo.
  <code>common/datastore.py</code> expone la misma interfaz sobre PostgreSQL o sobre
  memoria y elige autom&aacute;ticamente, de modo que el flujo de negocio y las tres se&ntilde;ales
  se observan igual en ambos entornos.</li>
</ul>

<div class="nota">
  El fallo de los buckets ilustra un riesgo caracter&iacute;stico de la observabilidad: un
  panel que <em>parece</em> funcionar y muestra cifras plausibles puede estar midiendo
  mal. No lo delat&oacute; el dashboard, sino contrastar el valor agregado con la latencia
  real observada en las trazas.
</div>

<h2>7. Despliegue en la nube</h2>

<p>La infraestructura est&aacute; descrita como c&oacute;digo en <code>terraform/</code>,
parametrizada y sin valores de cuenta en los archivos versionados. En ambas nubes el
Collector usa el <strong>patr&oacute;n sidecar</strong>: corre junto a la aplicaci&oacute;n
compartiendo el espacio de red, de modo que &eacute;sta exporta a <code>localhost:4317</code>
sin exponer ning&uacute;n puerto de telemetr&iacute;a. Durante el despliegue real en Cloud Run se
detectaron cuatro problemas que no aparecen en local:</p>

<table>
  <tr><th>S&iacute;ntoma</th><th>Causa</th><th>Correcci&oacute;n</th></tr>
  <tr><td>El Collector no arranca</td><td>El exporter <code>googlecloud</code> no admite <code>retry_on_failure</code> ni <code>sending_queue</code> en su nivel ra&iacute;z</td><td>Retirar ambas claves</td></tr>
  <tr><td>No llega telemetr&iacute;a pese a no haber errores</td><td>Cloud Run retira la CPU entre peticiones y el sidecar nunca llega a exportar sus lotes</td><td><code>cpu_idle = false</code></td></tr>
  <tr><td>M&eacute;tricas rechazadas</td><td>Managed Prometheus no admite dos puntos de la misma serie por petici&oacute;n, y <code>batch</code> agrupaba varios ciclos del reader</td><td>Retirar <code>batch</code> del pipeline de m&eacute;tricas</td></tr>
  <tr><td>service-b responde 404</td><td>El tr&aacute;fico saliente de Cloud Run sale a internet sin conector VPC, por lo que el ingress interno lo rechaza</td><td>Abrir el ingress y proteger con IAM: token OIDC del metadata server</td></tr>
</table>

<div class="nota">
  El segundo caso es el m&aacute;s instructivo: <strong>la telemetr&iacute;a se perd&iacute;a en
  silencio</strong>. No hab&iacute;a errores en los logs, el Collector informaba de un arranque
  correcto y la aplicaci&oacute;n respond&iacute;a con normalidad; simplemente nada llegaba al
  backend. Un pipeline de observabilidad tambi&eacute;n necesita que se verifique que observa.
</div>

<p>El Terraform de <strong>AWS ECS Fargate</strong> (VPC, ECR, ALB, Cloud Map, roles IAM
y el Collector como sidecar con exporters a X-Ray, CloudWatch Logs y EMF) se entrega
completo y versionado, pero <strong>no se aplic&oacute;</strong> por no disponer de una cuenta
de AWS.</p>

<h2>8. Evidencias de ejecuci&oacute;n</h2>

<p>Las capturas del entorno local se generan con
<code>scripts/capturar-evidencias.sh</code>, que dispara tr&aacute;fico real y fotograf&iacute;a cada
backend; al estar automatizadas no pueden desincronizarse del estado del sistema.</p>

<div class="ev-grid">
  <div class="ev ancho">
    <img src="evidencias/01-jaeger-traza-completa.png" alt="Traza completa en Jaeger">
    <div class="pie"><span class="et et-l">Local</span>
      <strong>Jaeger &mdash; traza completa.</strong> La cabecera indica
      <code>Services 2</code> y <code>Total Spans 13</code>: ambos microservicios bajo un
      &uacute;nico <code>trace_id</code>. La cascada distingue por color los spans de cada
      servicio y muestra la secuencia de negocio completa, de <code>order.process</code>
      a <code>order.compute_total</code>. <strong>Es la prueba de la propagaci&oacute;n W3C
      TraceContext</strong>: sin ella, service-b aparecer&iacute;a en una traza separada.</div>
  </div>

  <div class="ev ancho">
    <img src="evidencias/03-grafana-dashboard-slis.png" alt="Dashboard de Grafana">
    <div class="pie"><span class="et et-l">Local</span>
      <strong>Grafana &mdash; dashboard de 11 paneles.</strong> Los cuatro SLIs
      (disponibilidad, latencia p50/p95/p99, tasa de error y throughput), el overhead de
      CPU y memoria por contenedor, y tres paneles de salud del Collector: se&ntilde;ales
      aceptadas por tipo, errores &mdash;todos en cero&mdash; y ocupaci&oacute;n de la cola de
      exportaci&oacute;n. La tasa de error de 0,503&nbsp;% procede del endpoint
      <code>/fail</code>, que inyecta fallos deliberados para comprobar que el SLI
      reacciona.</div>
  </div>

  <div class="ev ancho">
    <img src="evidencias/09-gcp-cloud-run-sidecar.png" alt="Collector sidecar en Cloud Run">
    <div class="pie"><span class="et et-g">GCP</span>
      <strong>Cloud Run &mdash; el Collector como sidecar.</strong> El selector de
      contenedores de <code>service-a</code> lista <em>Contenedor de entrada: app</em> y
      <em>Contenedor: otel-collector</em>: dos contenedores en el mismo servicio. Entre
      las variables se ve <code>OTEL_EXPORTER_OTLP_ENDPOINT = http://localhost:4317</code>,
      que confirma que la aplicaci&oacute;n exporta al sidecar por la interfaz de red compartida,
      sin exponer puertos de telemetr&iacute;a al exterior.</div>
  </div>

  <div class="ev">
    <img src="evidencias/04-grafana-explore-logs-correlacionados.png" alt="Logs correlacionados">
    <div class="pie"><span class="et et-l">Local</span>
      <strong>Grafana Explore &mdash; logs por <code>trace_id</code>.</strong> Consulta
      LogQL sobre Loki usando el identificador como pivote; los <em>derived fields</em> lo
      convierten en enlace directo a la traza.</div>
  </div>

  <div class="ev">
    <img src="evidencias/06-gcp-cloud-trace-explorer.png" alt="Cloud Trace">
    <div class="pie"><span class="et et-g">GCP</span>
      <strong>Cloud Trace.</strong> Las facetas desglosan los spans por servicio:
      <code>service-a</code> y <code>service-b</code> emiten dentro del mismo conjunto de
      trazas. La propagaci&oacute;n funciona igual que en local, pese a que aqu&iacute; el salto
      atraviesa internet y exige un token OIDC.</div>
  </div>

  <div class="ev">
    <img src="evidencias/07-gcp-cloud-logging.png" alt="Cloud Logging">
    <div class="pie"><span class="et et-g">GCP</span>
      <strong>Cloud Logging.</strong> Consulta sobre el <code>logName</code> que declara
      el Collector. Se ven los mensajes de negocio y la llamada HTTPS entre servicios;
      cada entrada lleva el campo <code>trace</code> poblado.</div>
  </div>

  <div class="ev">
    <img src="evidencias/08-gcp-managed-prometheus.png" alt="Managed Prometheus">
    <div class="pie"><span class="et et-g">GCP</span>
      <strong>Managed Prometheus.</strong> La m&eacute;trica <code>http_requests_total</code>
      emitida por el SDK y reexportada por el sidecar; conserva el modelo de Prometheus,
      as&iacute; que las consultas PromQL del dashboard local sirven sin reescribirse.</div>
  </div>

  <div class="ev">
    <img src="evidencias/02-jaeger-busqueda-trazas.png" alt="Busqueda en Jaeger">
    <div class="pie"><span class="et et-l">Local</span>
      <strong>Jaeger &mdash; listado de trazas</strong> de <code>service-a</code> con su
      duraci&oacute;n y n&uacute;mero de spans.</div>
  </div>

  <div class="ev">
    <img src="evidencias/05-prometheus-targets.png" alt="Targets de Prometheus">
    <div class="pie"><span class="et et-l">Local</span>
      <strong>Prometheus &mdash; targets activos.</strong> Conviven el camino v&iacute;a
      Collector y el scraping directo, que act&uacute;a como control.</div>
  </div>
</div>

<h2>9. Conclusiones</h2>

<p>El pipeline cumple el objetivo: las tres se&ntilde;ales se emiten desde los microservicios,
se centralizan en un &uacute;nico Collector y resultan mutuamente navegables a trav&eacute;s del
<code>trace_id</code>, tanto en local como en Cloud Run. La propagaci&oacute;n de contexto W3C
qued&oacute; verificada de forma automatizada, no s&oacute;lo observada en una interfaz.</p>

<p>Dos aprendizajes destacan sobre la mec&aacute;nica de configuraci&oacute;n. El primero es que
<strong>la correlaci&oacute;n es una decisi&oacute;n de dise&ntilde;o, no una consecuencia autom&aacute;tica</strong>
de instrumentar: exige que el identificador viaje en las tres se&ntilde;ales con formato
consistente y que las herramientas sepan saltar entre ellas. El segundo es que
<strong>la telemetr&iacute;a tambi&eacute;n hay que verificarla</strong>: el error en los buckets
produc&iacute;a percentiles plausibles pero incorrectos, y en Cloud Run la telemetr&iacute;a se
perd&iacute;a sin un solo mensaje de error. Un dashboard equivocado durante un incidente es
peor que no tener dashboard, porque dirige la investigaci&oacute;n en la direcci&oacute;n err&oacute;nea.</p>

<p>Sobre el overhead, la conclusi&oacute;n pr&aacute;ctica es que el costo se concentra en CPU y en un
consumo base fijo de memoria, mientras que el impacto en la latencia percibida se
mantiene acotado gracias a la exportaci&oacute;n as&iacute;ncrona por lotes. Ese costo es ajustable
mediante muestreo y control de cardinalidad, lo que convierte la decisi&oacute;n en un
intercambio expl&iacute;cito entre profundidad de observabilidad y consumo de recursos, en
lugar de un precio fijo que haya que aceptar.</p>

</body>
</html>
"""


if __name__ == "__main__":
    sys.exit(generar())
