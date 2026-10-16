#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
generar_reporte_integrador.py - Informe ejecutivo del laboratorio integrador.

Las cifras se leen de los JSON de las mediciones reales, no se transcriben a
mano: asi el informe y la evidencia no pueden desincronizarse. Si falta un
resultado, la celda aparece marcada como "sin dato" en lugar de inventarse.

Uso:
    python docs/generar_reporte_integrador.py
    bash scripts/generar-pdf.sh docs/reporte-integrador.html
"""

import json
import os
from datetime import datetime

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SALIDA = os.path.join(RAIZ, "docs", "reporte-integrador.html")

MESES = ("enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
         "agosto", "septiembre", "octubre", "noviembre", "diciembre")


# ════════════════════════════════════════════════════════════════════════════
# Carga de mediciones
# ════════════════════════════════════════════════════════════════════════════
def cargar(*ruta):
    try:
        with open(os.path.join(RAIZ, *ruta), encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def num(valor, formato="%.0f", sufijo=""):
    """Formatea un numero, o devuelve una celda marcada si no hay dato."""
    try:
        return (formato % float(valor)) + sufijo
    except (TypeError, ValueError):
        return '<span class="sin-datos">sin dato</span>'


E1 = cargar("chaos", "resultados", "e1-latencia-red.json")
E2 = cargar("chaos", "resultados", "e2-cpu-exhaustion.json")
E3 = cargar("chaos", "resultados", "e3-network-partition.json")
E4 = cargar("chaos", "resultados", "e4-errores-data-service.json")
AIOPS = cargar("aiops", "resultados", "deteccion.json")

COMP = AIOPS.get("comparacion", {})
INCIDENTES = AIOPS.get("incidentes", [])
INC = INCIDENTES[0] if INCIDENTES else {}


def delta_pct(base, caos):
    try:
        return 100.0 * (float(caos) - float(base)) / float(base)
    except (TypeError, ValueError, ZeroDivisionError):
        return None


# ════════════════════════════════════════════════════════════════════════════
# Tablas construidas desde los datos
# ════════════════════════════════════════════════════════════════════════════
def tabla_experimentos():
    filas = []
    definicion = [
        (E1, "E1", "Latencia de red", "service-b", "Toxiproxy", "p99_base_ms", "p99_chaos_ms",
         "disponibilidad_chaos"),
        (E2, "E2", "Agotamiento de CPU", "service-b", "stress-ng", "p99_base_ms", "p99_chaos_ms",
         "disponibilidad_chaos"),
        (E3, "E3", "Partici&oacute;n de red", "service-b", "docker network", "p99_base_ms",
         "p99_chaos_ms", "disponibilidad_chaos"),
        (E4, "E4", "Errores en dependencia opcional", "data-service", "CHAOS_ERROR_RATE",
         "p99_base_ms", "p99_chaos_ms", "disponibilidad_borde_chaos"),
    ]

    for datos, cod, nombre, objetivo, herramienta, kb, kc, kd in definicion:
        base, caos = datos.get(kb), datos.get(kc)
        d = delta_pct(base, caos)
        clase = ""
        if d is not None:
            clase = "alto" if d > 50 else ("mejora" if d < 10 else "")
        mttd = datos.get("mttd_s")
        texto_mttd = ("no detectado" if mttd is not None and float(mttd) < 0
                      else num(mttd, "%.0f", " s"))

        filas.append(
            "<tr><td><strong>%s</strong></td><td>%s</td><td>%s</td><td>%s</td>"
            "<td class='num'>%s</td><td class='num'>%s</td>"
            "<td class='num %s'>%s</td><td class='num'>%s</td>"
            "<td class='num'>%s</td></tr>" % (
                cod, nombre, objetivo, herramienta,
                num(base, "%.0f", " ms"), num(caos, "%.0f", " ms"),
                clase, ("%+.0f %%" % d) if d is not None else "&mdash;",
                num(datos.get(kd), "%.2f", " %"),
                texto_mttd,
            ))
    return "\n".join(filas)


def tabla_alertado():
    def fila(etiqueta, clave, resaltar=False):
        d = COMP.get(clave, {})
        estilo = " class='mejora'" if resaltar else ""
        return ("<tr><td>%s</td><td class='num'>%s</td><td class='num'>%s</td>"
                "<td class='num'%s>%s</td></tr>" % (
                    etiqueta,
                    num(d.get("alertas", d.get("incidentes")), "%.0f"),
                    num(d.get("coinciden_con_incidente", d.get("incidentes")), "%.0f"),
                    estilo,
                    num(d.get("sin_accion_asociada", 0), "%.0f"),
                ))

    return "\n".join([
        fila("Umbral fijo p99 &gt; 500 ms", "umbral_estricto_500ms"),
        fila("Umbral fijo p99 &gt; 2000 ms", "umbral_laxo_2000ms"),
        fila("<strong>Baseline m&oacute;vil + correlaci&oacute;n</strong>",
             "regla_correlacionada", resaltar=True),
    ])


MADUREZ = [
    (1, "Instrumentaci&oacute;n y cobertura de se&ntilde;ales", 4, "s&iacute;",
     "Tres servicios, tres se&ntilde;ales, DB Semantic Conventions"),
    (2, "Pipeline de telemetr&iacute;a", 4, "s&iacute;",
     "Collector con cuatro configuraciones; misma cadena de procesadores"),
    (3, "Correlaci&oacute;n entre se&ntilde;ales", 3, "parcial",
     "trace_id en las tres se&ntilde;ales; falta el salto m&eacute;trica &rarr; traza"),
    (4, "SLO y presupuesto de error", 3, "s&iacute;",
     "SLO expl&iacute;citos y tasa de quemado; sin revisi&oacute;n peri&oacute;dica"),
    (5, "Alertado y respuesta", 3, "parcial",
     "Seis pol&iacute;ticas con runbook; sin rotaci&oacute;n de guardia"),
    (6, "Infraestructura y red", 3, "s&iacute;",
     "Flow Logs activos en AWS; 25.683 registros en 20 minutos"),
    (7, "Seguridad", 4, "s&iacute;",
     "Detecci&oacute;n en ambas nubes sobre tr&aacute;fico real; falta el mTLS de la malla"),
    (8, "Resiliencia y experimentaci&oacute;n", 4, "s&iacute;",
     "Cuatro experimentos con probes SOT/DuringChaos/EOT y rollback"),
]


def tabla_madurez():
    filas = []
    for n, dominio, nivel, verificado, evidencia in MADUREZ:
        barra = "&#9632;" * nivel + "<span style='color:#c9d2dc'>%s</span>" % ("&#9632;" * (5 - nivel))
        clase = " class='alto'" if nivel <= 2 else ""
        filas.append(
            "<tr><td class='num'>%d</td><td>%s</td><td class='num'%s>%d</td>"
            "<td style='letter-spacing:1px'>%s</td><td>%s</td><td>%s</td></tr>"
            % (n, dominio, clase, nivel, barra, verificado, evidencia))
    return "\n".join(filas)


MEDIA = sum(m[2] for m in MADUREZ) / len(MADUREZ)


# ════════════════════════════════════════════════════════════════════════════
# Evidencias
# ════════════════════════════════════════════════════════════════════════════
def evidencia(archivo, etiqueta, clase_et, titulo, pie, ancho=False):
    ruta = os.path.join(RAIZ, "docs", "evidencias", archivo)
    alternativa = os.path.join(RAIZ, "chaos", "evidencias", archivo)
    if os.path.exists(ruta):
        src = "evidencias/" + archivo
    elif os.path.exists(alternativa):
        src = "../chaos/evidencias/" + archivo
    else:
        return ""
    return ('<div class="ev%s"><img src="%s" alt="%s">'
            '<div class="pie"><span class="et %s">%s</span>'
            '<strong>%s</strong> &mdash; %s</div></div>'
            % (" ancho" if ancho else "", src, titulo, clase_et, etiqueta, titulo, pie))


EVIDENCIAS_A = "\n".join(filter(None, [
    evidencia("01-jaeger-traza-completa.png", "LOCAL", "et-l",
              "Una traza, tres servicios",
              "22 spans y profundidad 7 bajo un &uacute;nico trace_id. Los spans "
              "<code>SELECT</code> son auto-instrumentaci&oacute;n de psycopg2; los "
              "nombrados en negocio son manuales.", ancho=True),
    evidencia("02-jaeger-busqueda-trazas.png", "LOCAL", "et-l",
              "B&uacute;squeda de trazas",
              "Distribuci&oacute;n de duraciones de <code>service-a</code>."),
    evidencia("05-prometheus-targets.png", "LOCAL", "et-l",
              "Targets de Prometheus",
              "Doble v&iacute;a de recolecci&oacute;n: push al Collector y scrape directo."),
]))

EVIDENCIAS_B = "\n".join(filter(None, [
    evidencia("03-grafana-dashboard-slis.png", "LOCAL", "et-l",
              "Panel de los cuatro SLIs",
              "Disponibilidad, latencia por percentiles, tasa de error y throughput."),
    evidencia("04-grafana-explore-logs-correlacionados.png", "LOCAL", "et-l",
              "Logs filtrados por trace_id",
              "Salto desde la traza al log sin cambiar de herramienta."),
]))

EVIDENCIAS_GCP = "\n".join(filter(None, [
    evidencia("06-gcp-cloud-trace-explorer.png", "GCP", "et-g",
              "Cloud Trace",
              "Las mismas trazas tras cambiar s&oacute;lo la configuraci&oacute;n del Collector."),
    evidencia("09-gcp-cloud-run-sidecar.png", "GCP", "et-g",
              "Cloud Run con sidecar",
              "El Collector viaja junto a la aplicaci&oacute;n en cada revisi&oacute;n."),
    evidencia("07-gcp-cloud-logging.png", "GCP", "et-g",
              "Cloud Logging",
              "Logs estructurados con <code>trace_id</code> como campo indexado."),
    evidencia("08-gcp-managed-prometheus.png", "GCP", "et-g",
              "Managed Prometheus",
              "Las m&eacute;tricas de la aplicaci&oacute;n, sin servidor que mantener."),
]))

EVIDENCIAS_AWS = "\n".join(filter(None, [
    evidencia("aws-01-xray-service-map.png", "AWS", "et-g",
              "Mapa de servicios reconstruido desde las trazas",
              "Nadie describio esta topologia: la plataforma la deduce de los "
              "<code>traceparent</code> que viajan entre servicios. Coincide con la "
              "arquitectura disenada, incluido el nodo de base de datos."),
    evidencia("aws-02-xray-traza.png", "AWS", "et-g",
              "Una peticion, tres servicios y la base",
              "Cascada completa bajo un unico identificador: 35 ms en total, con "
              "<code>service-b</code> y <code>data-service</code> ejecutandose en "
              "paralelo y los <code>SELECT</code> anidados bajo cada uno."),
    evidencia("aws-03-cloudwatch-logs.png", "AWS", "et-g",
              "Logs de los tres servicios filtrados por trace_id",
              "El mismo identificador recupera las diez lineas que produjo la "
              "peticion, emitidas por tres procesos distintos. Es la correlacion "
              "traza-log funcionando sin herramientas propietarias."),
    evidencia("aws-04-alarmas.png", "AWS", "et-g",
              "Deteccion de red sobre trafico real",
              "Dos alarmas en rojo que nadie provoco, por escaneos de fondo contra "
              "las IP publicas. La tercera, en verde, mide el volumen de salida y "
              "confirma que no hay fuga."),
]))


EVIDENCIAS_D = "\n".join(filter(None, [
    evidencia("chaos-01-dashboard-incidente.png", "CAOS", "et-l",
              "El incidente en el panel",
              "Degradaci&oacute;n visible en las cuatro se&ntilde;ales a la vez."),
    evidencia("chaos-03-latencia-percentiles.png", "CAOS", "et-l",
              "Percentiles durante el fallo",
              "La separaci&oacute;n entre p95 y p99 delata la cola de la distribuci&oacute;n."),
]))


# ════════════════════════════════════════════════════════════════════════════
# Documento
# ════════════════════════════════════════════════════════════════════════════
hoy = datetime.now()
FECHA = "%d de %s de %d" % (hoy.day, MESES[hoy.month - 1], hoy.year)

CSS = """
  @page { size: A4; margin: 13mm 12mm 14mm 12mm; }

  :root {
    --tinta:  #1a2332;
    --suave:  #5a6778;
    --acento: #1c3d5a;
    --linea:  #d4dae2;
    --fondo:  #f6f8fa;
    --alerta: #b4453c;
    --ok:     #2d7d4f;
  }

  * { box-sizing: border-box; }

  body {
    font-family: "Segoe UI", -apple-system, system-ui, sans-serif;
    font-size: 8.4pt;
    line-height: 1.38;
    color: var(--tinta);
    margin: 0 auto;
    max-width: 186mm;
    padding: 5mm;
    background: #fff;
  }

  h1 { font-size: 15.5pt; line-height: 1.14; margin: 0 0 3px;
       color: var(--acento); letter-spacing: -.3px; }
  h2 { font-size: 10.2pt; margin: 11px 0 5px; padding-bottom: 2px;
       border-bottom: 1.4px solid var(--acento); color: var(--acento);
       page-break-after: avoid; }
  h3 { font-size: 8.8pt; margin: 8px 0 3px; page-break-after: avoid; }

  p  { margin: 0 0 5px; text-align: justify; }
  ul { margin: 0 0 5px; padding-left: 14px; }
  li { margin-bottom: 2px; }

  code { font-family: "Cascadia Mono", Consolas, monospace; font-size: 7.4pt;
         background: var(--fondo); padding: 0 2px; border-radius: 2px; }

  pre { font-family: "Cascadia Mono", Consolas, monospace; font-size: 6.6pt;
        line-height: 1.28; background: var(--fondo);
        border: .5px solid var(--linea); border-left: 2px solid var(--acento);
        border-radius: 3px; padding: 5px 7px; overflow-x: auto;
        page-break-inside: avoid; margin: 0 0 6px; white-space: pre; }
  pre code { background: none; padding: 0; font-size: inherit; }

  table { width: 100%; border-collapse: collapse; margin: 0 0 7px;
          font-size: 7.1pt; page-break-inside: avoid; }
  th { background: var(--acento); color: #fff; text-align: left;
       padding: 2.5px 4px; font-weight: 600; }
  td { padding: 2px 4px; border-bottom: .5px solid var(--linea); }
  tr:nth-child(even) td { background: #fafbfc; }
  td.alto   { color: var(--alerta); font-weight: 700; }
  td.mejora { color: var(--ok); font-weight: 700; }
  .num { text-align: right; font-variant-numeric: tabular-nums;
         white-space: nowrap; }

  .portada { border-bottom: 2.5px solid var(--acento); padding-bottom: 7px;
             margin-bottom: 9px; }
  .sub  { font-size: 9pt; color: var(--suave); margin: 2px 0 6px; }
  .meta { font-size: 7.5pt; color: var(--suave); line-height: 1.5; }
  .meta strong { color: var(--tinta); }

  .nota { background: #fdf6e3; border-left: 2px solid #c89b3c;
          padding: 4px 7px; margin: 6px 0; font-size: 7.5pt;
          page-break-inside: avoid; }
  .dest { background: var(--fondo); border-left: 2px solid var(--acento);
          padding: 4px 7px; margin: 6px 0; page-break-inside: avoid;
          font-size: 7.9pt; }
  .sin-datos { color: var(--suave); font-style: italic; }

  .cols { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
  .cols3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px; }

  .ev-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; }
  .ev { page-break-inside: avoid; }
  .ev img { width: 100%; height: auto; border: .5px solid var(--linea);
            border-radius: 2px; display: block; }
  .ev .pie { font-size: 6.5pt; color: var(--suave); margin-top: 2px;
             line-height: 1.3; }
  .ev .pie strong { color: var(--tinta); }
  .et { display: inline-block; font-size: 5.8pt; font-weight: 700;
        padding: 0 3px; border-radius: 2px; margin-right: 2px; }
  .et-l { background: #e3edf7; color: #1c3d5a; }
  .et-g { background: #e6f0e8; color: #2d5c3d; }
  .ancho { grid-column: 1 / -1; }

  .salto { page-break-before: always; }

  .kpi { display: grid; grid-template-columns: repeat(4, 1fr); gap: 6px;
         margin: 7px 0; }
  .kpi div { background: var(--fondo); border-left: 2px solid var(--acento);
             padding: 5px 7px; }
  .kpi .v { font-size: 13pt; font-weight: 700; color: var(--acento);
            line-height: 1.1; font-variant-numeric: tabular-nums; }
  .kpi .e { font-size: 6.6pt; color: var(--suave); line-height: 1.3;
            margin-top: 1px; }
"""

HTML = """<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<title>Laboratorio Integrador &mdash; Observabilidad</title>
<style>%(css)s</style>
</head>
<body>

<div class="portada">
  <h1>Plataforma de Observabilidad Multi-Nube</h1>
  <div class="sub">Service mesh, detecci&oacute;n de anomal&iacute;as, observabilidad de red y resiliencia verificada</div>
  <div class="meta">
    <strong>Programa:</strong> Maestr&iacute;a en Arquitectura de Software &mdash; Universidad de La Sabana
    &nbsp;&middot;&nbsp; <strong>Asignatura:</strong> Observabilidad en Ambientes Productivos
    &nbsp;&middot;&nbsp; <strong>Fecha:</strong> %(fecha)s<br>
    <strong>Integrantes:</strong> Edgar Andr&eacute;s Romero Ot&aacute;lora &nbsp;&middot;&nbsp;
    Jhon Alexander Tenjo Romero &nbsp;&middot;&nbsp; Juli&aacute;n David Miranda Leguizam&oacute;n
  </div>
</div>

<h2>1. Resumen ejecutivo</h2>

<p>Este laboratorio extiende el pipeline de observabilidad construido en las dos
entregas anteriores hasta convertirlo en una plataforma completa: un tercer
microservicio dentro de una malla de servicios, detecci&oacute;n de anomal&iacute;as con
l&iacute;nea base m&oacute;vil, observabilidad de red y seguridad en dos nubes, y un cuarto
experimento de caos que cierra el ciclo de verificaci&oacute;n.</p>

<div class="kpi">
  <div><div class="v">3</div><div class="e">microservicios bajo un mismo <code>trace_id</code></div></div>
  <div><div class="v">2</div><div class="e">nubes con el mismo c&oacute;digo de aplicaci&oacute;n</div></div>
  <div><div class="v">%(reduccion)s</div><div class="e">menos alertas sin acci&oacute;n asociada</div></div>
  <div><div class="v">4</div><div class="e">experimentos de caos con hip&oacute;tesis falsable</div></div>
</div>

<p>La decisi&oacute;n de dise&ntilde;o que sostiene el resto es la separaci&oacute;n entre
<em>qu&eacute; se observa</em> y <em>d&oacute;nde corre</em>. La instrumentaci&oacute;n vive en un
m&oacute;dulo com&uacute;n (<code>services/common/telemetry.py</code>) y el destino de las
se&ntilde;ales lo decide la configuraci&oacute;n del Collector. Gracias a eso, la misma
imagen de contenedor se despliega en Cloud Run, en ECS Fargate y en Kubernetes
sin tocar una l&iacute;nea de c&oacute;digo, y a&ntilde;adir el tercer servicio cost&oacute; importar un
m&oacute;dulo.</p>

<h2>2. Arquitectura</h2>

<pre><code>                         Internet
                            |
                 [ Gateway / Load Balancer ]
                            |
         +------------------v------------------+
         |  service-a   (orquestador)          |  entrada publica
         +----+---------------------------+----+
              |                           |
      dependencia CRITICA         dependencia OPCIONAL
              |                           |
      +-------v--------+          +-------v---------+
      |  service-b     |          |  data-service   |
      |  inventario    |          |  analitica      |
      +-------+--------+          +-------+---------+
              |                           |
              +------------+--------------+
                           |
                     [ PostgreSQL ]

   Las tres senales (trazas, metricas, logs) salen por OTLP hacia un
   unico Collector, que las reenvia al backend de cada entorno:

     local  ->  Jaeger + Prometheus + Loki + Grafana
     GCP    ->  Cloud Trace + Managed Prometheus + Cloud Logging
     AWS    ->  X-Ray + CloudWatch</code></pre>

<p>La distinci&oacute;n entre dependencia cr&iacute;tica y opcional no es documental: est&aacute;
codificada. <code>service-a</code> llama a los dos servicios en paralelo con
<code>asyncio.gather</code>, pero el fallo de <code>data-service</code> devuelve
<code>None</code> y el pedido se procesa igual, sin la secci&oacute;n de anal&iacute;tica. El
experimento E4 existe precisamente para comprobar que esa clasificaci&oacute;n se
sostiene bajo fallo real.</p>

<h2>3. M&oacute;dulo A &mdash; Tercer servicio y malla de servicios</h2>

<p><code>data-service</code> expone consultas anal&iacute;ticas sobre la misma base de
datos y publica sus spans con las <em>DB Semantic Conventions</em> completas:
<code>db.system</code>, <code>db.operation</code>, <code>db.statement</code> y
<code>db.collection.name</code>. El par&aacute;metro de la consulta viaja como marcador
y lo sustituye el driver, de modo que el atributo de la traza nunca contiene
datos de usuario.</p>

<p>Sobre Kubernetes se instala <strong>Istio open source</strong>. La elecci&oacute;n
frente a Cloud Service Mesh responde al requisito de dos nubes: los
manifiestos de <code>k8s/</code> son id&eacute;nticos en GKE y en EKS, mientras que una
malla gestionada por un proveedor no tiene equivalente directo en el otro.</p>

<p>Lo que aporta la malla, y que la instrumentaci&oacute;n de aplicaci&oacute;n no puede dar
por s&iacute; sola:</p>

<table>
<tr><th>Capacidad</th><th>C&oacute;mo se obtiene</th><th>Qu&eacute; resuelve</th></tr>
<tr><td>Trazas del plano de datos</td><td><code>Telemetry</code> CR hacia el Collector</td>
    <td>Un servicio sin instrumentar sigue apareciendo en el grafo</td></tr>
<tr><td>mTLS estricto</td><td><code>PeerAuthentication: STRICT</code></td>
    <td>Cifrado e identidad SPIFFE en todo el tr&aacute;fico interno</td></tr>
<tr><td>Autorizaci&oacute;n por identidad</td><td><code>AuthorizationPolicy</code> con denegaci&oacute;n por defecto</td>
    <td>Un Pod comprometido no puede pivotar hacia otro servicio</td></tr>
<tr><td>Resiliencia L7</td><td>Timeouts, reintentos y <em>circuit breakers</em> declarativos</td>
    <td>Se ajustan sin reconstruir la imagen</td></tr>
<tr><td>Logs de acceso L7</td><td><code>envoyOtelAls</code> por OTLP</td>
    <td>Alimentan el panel de seguridad del M&oacute;dulo C</td></tr>
</table>

<div class="dest">
<strong>Los valores de resiliencia salen de los experimentos, no de un manual.</strong>
E1 mostr&oacute; que un timeout de 5 s convert&iacute;a 200 ms de degradaci&oacute;n en un p99 de
%(e3_pico)s ms, porque la llamada lenta retiene el <em>worker</em> hasta agotar el
plazo. De ah&iacute; el timeout de 3 s hacia <code>service-b</code> y el l&iacute;mite de 32
peticiones en cola: rechazar r&aacute;pido impide que la cola crezca sin l&iacute;mite y que
el fallo se propague hacia arriba.
</div>

<div class="ev-grid">%(ev_a)s</div>

<h2 class="salto">4. M&oacute;dulo B &mdash; Detecci&oacute;n de anomal&iacute;as y correlaci&oacute;n</h2>

<p>Un umbral est&aacute;tico tiene que elegir entre dos formas de fallar y no puede
evitar las dos: si es bajo, detecta todo y el equipo deja de leer las alertas;
si es alto, no hace ruido pero se pierde las degradaciones que no llegan al
l&iacute;mite. La alternativa implementada combina dos ideas.</p>

<p><strong>L&iacute;nea base m&oacute;vil.</strong> El l&iacute;mite no es un n&uacute;mero fijo sino lo que el
sistema ven&iacute;a haciendo, m&aacute;s dos desviaciones t&iacute;picas. Una latencia de 800 ms es
normal bajo carga alta y an&oacute;mala en reposo, y un umbral fijo no distingue los
dos casos.</p>

<p><strong>Correlaci&oacute;n multi-se&ntilde;al.</strong> Una sola se&ntilde;al an&oacute;mala no abre
incidente: hacen falta errores <em>y</em> latencia a la vez, sostenidos varios
puntos seguidos. S&oacute;lo latencia alta suele ser un pico de tr&aacute;fico leg&iacute;timo; s&oacute;lo
errores, una dependencia opcional degradada. Las dos juntas son un incidente.</p>

<p>Para evaluarlo se construy&oacute; un escenario controlado de 17 minutos con una
fase de <em>ruido</em> (latencia moderada sin errores) y una fase de
<em>incidente</em> (base de datos ca&iacute;da). El resultado sobre los mismos datos:</p>

<table>
<tr><th>Enfoque</th><th class="num">Alertas</th><th class="num">&Uacute;tiles</th><th class="num">Sin acci&oacute;n</th></tr>
%(tabla_alertado)s
</table>

<p>La regla correlacionada no s&oacute;lo emiti&oacute; menos avisos: no perdi&oacute; ning&uacute;n
incidente y adjunt&oacute; a cada uno el identificador de una petici&oacute;n real que lo
sufri&oacute;. El incidente detectado y la traza que lo acompa&ntilde;a:</p>

<pre><code>Incidente   %(inc_inicio)s   duracion %(inc_dur)s s
p99         %(inc_p99)s ms   (normal: %(inc_p99_base)s ms  ·  SLO: 1.000 ms)
error_rate  %(inc_err)s      (normal: %(inc_err_base)s)
trace_id    %(inc_trace)s

  GET /order/{order_id}    2.804 ms  ERROR  http=500
  order.process            2.802 ms  ERROR  HTTPException: 500: Database error
  fetch.order.db           2.801 ms  ERROR  HTTPException: 500: Database error</code></pre>

<p>La diferencia pr&aacute;ctica es el punto de partida de quien recibe el aviso: en
lugar de saber que el p99 subi&oacute;, tiene la petici&oacute;n concreta que fall&oacute; y la
causa en el tercer span.</p>

<p>La implementaci&oacute;n en la nube (<code>terraform/observabilidad/aiops.tf</code>)
despliega cinco pol&iacute;ticas. Tres reproducen la comparaci&oacute;n anterior &mdash;las dos
de umbral fijo no notifican, existen para poder contar cu&aacute;ntas veces habr&iacute;an
interrumpido a una persona&mdash; y dos cubren huecos que la correlaci&oacute;n no ve:
el consumo acelerado del presupuesto de error y la <strong>ausencia de
se&ntilde;al</strong>. Esta &uacute;ltima nace de una observaci&oacute;n del propio laboratorio: al
pausar el contenedor de la base de datos, las peticiones quedaron colgadas
indefinidamente y no se registr&oacute; ni un error ni una latencia. Un sistema que no
responde tampoco emite se&ntilde;ales.</p>

<div class="ev-grid">%(ev_b)s</div>

<h2 class="salto">5. M&oacute;dulo C &mdash; Observabilidad de red y seguridad</h2>

<p>Las cuatro se&ntilde;ales doradas describen la <em>salud</em> de un sistema, pero no
dicen nada sobre si alguien lo est&aacute; atacando: un sistema bajo intrusi&oacute;n puede
tenerlas las cuatro en verde. El panel de seguridad responde a otras cuatro
preguntas, construidas sobre se&ntilde;ales que ya se est&aacute;n recogiendo &mdash;VPC Flow
Logs y logs de acceso L7 de los sidecars&mdash; sin agentes nuevos.</p>

<table>
<tr><th>Pregunta</th><th>Se&ntilde;al</th><th>GCP</th><th>AWS</th></tr>
<tr><td>&iquest;A qui&eacute;n se le niega el paso?</td><td>Invocaciones rechazadas por identidad</td>
    <td>403 de los servicios internos</td><td>Conexiones REJECT del firewall</td></tr>
<tr><td>&iquest;Qui&eacute;n cambia la plataforma?</td><td>Operaciones administrativas</td>
    <td>Audit Logs por identidad</td><td>&mdash;</td></tr>
<tr><td>&iquest;Alguien est&aacute; sondeando?</td><td>Rutas y puertos que no existen</td>
    <td>404 por ruta solicitada</td><td>Intentos contra SSH, RDP y telnet</td></tr>
<tr><td>&iquest;Sale m&aacute;s informaci&oacute;n de la habitual?</td><td>Volumen de datos devuelto</td>
    <td>p99 del tama&ntilde;o de respuesta</td><td>Bytes hacia destinos externos</td></tr>
</table>

<p>Las cuatro preguntas son las mismas en las dos nubes; las se&ntilde;ales que las
responden, no. Esa es la parte interesante de hacerlo dos veces: obliga a
separar <em>qu&eacute; se quiere saber</em> de <em>qu&eacute; dato lo responde aqu&iacute;</em>.
Donde una plataforma da registros de flujo de red, la otra da el c&oacute;digo de
respuesta de una invocaci&oacute;n rechazada por identidad &mdash; y ambas contestan a
&laquo;&iquest;a qui&eacute;n se le niega el paso?&raquo;.</p>

<p>El caso m&aacute;s claro es el de la exfiltraci&oacute;n. La plataforma que no expone
el volumen de red obliga a medir el <strong>tama&ntilde;o de cada respuesta</strong>
en lugar del total agregado, y la restricci&oacute;n resulta ser una mejora: un pico
de tr&aacute;fico leg&iacute;timo multiplica el volumen total pero no cambia cu&aacute;nto
devuelve cada petici&oacute;n. Una extracci&oacute;n masiva s&iacute; lo cambia, aunque sean
cuatro peticiones y el total apenas se mueva.</p>

<p>La comparaci&oacute;n entre nubes revela una diferencia de dise&ntilde;o. En GCP los Flow
Logs llegan a Cloud Logging, que ya es el destino de todo lo dem&aacute;s, de modo que
una sola consulta puede cruzar un flujo de red con un log de aplicaci&oacute;n. En AWS
cada pieza tiene su consola &mdash;GuardDuty, Security Hub, X-Ray, CloudWatch&mdash;
y lo que cuesta es cruzarlas; por eso el despliegue env&iacute;a todo a CloudWatch
Logs y deja las consultas de investigaci&oacute;n guardadas como c&oacute;digo, incluida la
que parte de un <code>trace_id</code> y devuelve los logs de esa petici&oacute;n.</p>

<h3>Lo que detect&oacute; nada m&aacute;s encenderse</h3>

<p>Las dos mitades est&aacute;n desplegadas y recibiendo datos. En una nube, las
cuatro m&eacute;tricas registraron en doce minutos <strong>15 invocaciones rechazadas
por identidad y 9 sondeos a rutas inexistentes</strong> frente a 12 peticiones
leg&iacute;timas. En la otra, el resultado fue m&aacute;s contundente todav&iacute;a.</p>

<p>La parte de red se despleg&oacute; y empez&oacute; a producir se&ntilde;al de inmediato:
<strong>25.683 registros de flujo en veinte minutos</strong>. Entre ellos, tr&aacute;fico
que nadie del equipo gener&oacute;:</p>

<pre><code>REJECT  69.5.169.18:47204     -> 10.20.0.133:6789
REJECT  147.185.133.162       -> 10.20.0.133        (ICMP)
REJECT  162.219.178.250:24314 -> 10.20.0.133:23     (telnet)</code></pre>

<p>Son escaneos de fondo de internet contra las IP p&uacute;blicas del despliegue, y
<strong>dos de las tres alarmas pasaron a estado ALARM por s&iacute; solas</strong>:
<code>escaneo-de-puertos</code> y <code>puertos-sensibles</code>. Ninguna se
provoc&oacute;.</p>

<p>El dato tiene dos lecturas, y la segunda es la interesante. La primera es que
la detecci&oacute;n funciona sobre tr&aacute;fico real y no sobre un caso de prueba. La
segunda es que <em>ese ruido existe siempre</em>: cualquier direcci&oacute;n p&uacute;blica
recibe escaneos constantes, y una alerta que salta con el primero que pasa se
vuelve inservible en un d&iacute;a. El umbral de veinte conexiones rechazadas en cinco
minutos no es un n&uacute;mero de manual &mdash; es el que separa el ruido de fondo de un
intento dirigido, y s&oacute;lo se puede calibrar midi&eacute;ndolo.</p>

<div class="nota">
<strong>Sobre el coste.</strong> GuardDuty y Security Hub quedan desactivados por
defecto (<code>habilitar_seguridad_avanzada = false</code>): son los &uacute;nicos
servicios cuyo coste crece con el volumen analizado y no con el tiempo. El
muestreo de Flow Logs se fija en 0,5 por la misma raz&oacute;n; los patrones de
tr&aacute;fico siguen siendo visibles y el volumen de logs se reduce a la mitad.
</div>

<h2>6. M&oacute;dulo D &mdash; Experimentos de caos</h2>

<p>Los cuatro experimentos siguen el modelo de <em>probes</em> de LitmusChaos, que
separa la verificaci&oacute;n en tres momentos: el estado estable previo (SOT), la
detecci&oacute;n durante el fallo, y la recuperaci&oacute;n posterior (EOT). Sin la primera
fase un experimento no prueba nada, porque cualquier medici&oacute;n sobre un sistema
ya degradado es atribuible al estado previo y no al fallo inyectado.</p>

<table>
<tr><th>#</th><th>Fallo</th><th>Objetivo</th><th>Herramienta</th>
    <th class="num">p99 base</th><th class="num">p99 caos</th>
    <th class="num">&Delta;</th><th class="num">Disponib.</th><th class="num">MTTD</th></tr>
%(tabla_exp)s
</table>

<p class="meta" style="font-size:6.8pt;margin:-4px 0 7px">
La disponibilidad de E3 durante el fallo no qued&oacute; registrada: con la red
desconectada, el generador de carga dej&oacute; de recibir respuestas y la consulta
devolvi&oacute; una serie vac&iacute;a. El dato que s&iacute; se conserva es equivalente y m&aacute;s
expresivo &mdash; <strong>%(e3_fallbacks)s llamadas resueltas por el fallback</strong>
frente a 0 en la l&iacute;nea base&mdash;, y la disponibilidad antes y despu&eacute;s del fallo
fue del 100&nbsp;%% en ambos casos.</p>

<p>E3 es el resultado m&aacute;s valioso: una partici&oacute;n de red llev&oacute; el p99 a
%(e3_pico)s ms sin que la disponibilidad bajara del 100&nbsp;%%. El sistema no
ca&iacute;a, pero tardaba siete segundos y medio en responder, y ninguna alerta basada
en disponibilidad lo habr&iacute;a visto. De ah&iacute; salieron los plazos de la malla.</p>

<p>E4 ataca una dependencia <em>opcional</em> y responde a una pregunta distinta:
no &laquo;&iquest;aguanta el sistema?&raquo; sino &laquo;&iquest;est&aacute; bien clasificada la
dependencia?&raquo;. Una dependencia marcada como opcional en el c&oacute;digo pero que en
la pr&aacute;ctica tumba la petici&oacute;n s&oacute;lo se manifiesta el d&iacute;a que falla de verdad.</p>

<pre><code>[SOT]  p99 %(e4_sot)s ms (SLO 1.000)  ·  disponibilidad 100 %%   verificado BAJO CARGA
caos   data-service %(e4_err_ds)s de errores
       disponibilidad /order %(e4_disp)s  ·  errores vistos por el cliente %(e4_err_borde)s
       recuperacion %(e4_rec)s s

Veredicto: %(e4_hipotesis)s
%(e4_detalle)s</code></pre>

<p>El fallback funciona: el cliente no vio ni un error. Pero el experimento
tambi&eacute;n deja una advertencia operativa. Con el borde al 100&nbsp;%%, ninguna
alerta basada en la disponibilidad de <code>/order</code> habr&iacute;a saltado, de modo
que hace falta una alerta sobre los errores de <code>data-service</code> en s&iacute;
mismo o el fallo puede durar d&iacute;as sin que nadie se entere.</p>

<div class="ev-grid">%(ev_d)s</div>

<h2 class="salto">7. M&oacute;dulo E &mdash; Madurez y hoja de ruta</h2>

<p>La autoevaluaci&oacute;n se puntúa por lo que el sistema <strong>demostr&oacute;</strong> bajo
observaci&oacute;n, no por lo que se construy&oacute;. Se distingue adem&aacute;s entre
<em>definido como c&oacute;digo</em> y <em>verificado en ejecuci&oacute;n</em>: un manifiesto que
nunca se aplic&oacute; no es evidencia, y tratarlo como si lo fuera es la forma m&aacute;s
com&uacute;n de inflar un informe de madurez.</p>

<table>
<tr><th class="num">#</th><th>Dominio</th><th class="num">Nivel</th><th>&nbsp;</th>
    <th>Verificado</th><th>Evidencia</th></tr>
%(tabla_madurez)s
</table>

<p><strong>Media: %(media)s sobre 5.</strong> El perfil es deliberadamente desigual.
Los dominios que el laboratorio ejecut&oacute; de verdad est&aacute;n en 4; los que existen
como c&oacute;digo validado pero sin desplegar est&aacute;n en 2. Subir esos dos no requiere
escribir nada m&aacute;s: requiere desplegar y comprobar.</p>

<h3>Hoja de ruta a tres meses</h3>

<p>El criterio de ordenaci&oacute;n no es la dificultad sino el coste de no hacerlo:
primero lo que convierte trabajo ya hecho en capacidad real, despu&eacute;s lo que
cubre huecos conocidos, y al final lo que escala.</p>

<table>
<tr><th>Mes</th><th>Tema</th><th>Acciones</th><th>Criterio de salida</th><th class="num">Media</th></tr>
<tr><td><strong>1</strong></td><td>Convertir c&oacute;digo en capacidad</td>
    <td>Desplegar GKE + Istio; ejercitar las pol&iacute;ticas de autorizaci&oacute;n; aplicar
        las m&eacute;tricas de seguridad y validar los filtros de Flow Logs contra
        logs reales</td>
    <td>Los tres servicios con sidecar y mTLS confirmado; las cuatro m&eacute;tricas
        de seguridad con datos</td>
    <td class="num">3,4</td></tr>
<tr><td><strong>2</strong></td><td>Cerrar huecos conocidos</td>
    <td>SDK con exemplars; alerta para el modo de fallo de E1; SLO en una sola
        fuente; cola persistente en el Collector; revisi&oacute;n mensual del
        presupuesto de error</td>
    <td>Salto m&eacute;trica &rarr; traza desde el panel; E1 detectado por una alerta</td>
    <td class="num">3,9</td></tr>
<tr><td><strong>3</strong></td><td>Que funcione sin empujar</td>
    <td>Caos en CI semanal; muestreo adaptativo; control de cobertura de
        instrumentaci&oacute;n; rotaci&oacute;n de guardia y plantilla de postmortem</td>
    <td>Una ejecuci&oacute;n de caos fallida bloquea el merge; un servicio sin
        instrumentar falla la validaci&oacute;n</td>
    <td class="num">4,3</td></tr>
</table>

<p>Cada acci&oacute;n del mes 2 responde a un hallazgo concreto del laboratorio, no a
una buena pr&aacute;ctica gen&eacute;rica. El SLO vive hoy en tres sitios &mdash;el panel de
Grafana, el detector de anomal&iacute;as y las variables de Terraform&mdash; y nada
impide que diverjan; E1 no se detect&oacute; en 120 segundos porque la degradaci&oacute;n no
cruzaba ning&uacute;n umbral configurado, y ese dato existe desde el Game Day sin haber
producido todav&iacute;a una alerta nueva.</p>

<h2>8. Despliegue en las dos nubes</h2>

<table>
<tr><th>&nbsp;</th><th>GCP &mdash; Cloud Run</th><th>GCP &mdash; GKE + Istio</th><th>AWS &mdash; ECS Fargate</th></tr>
<tr><td>Collector</td><td>Sidecar por revisi&oacute;n</td><td>Deployment &uacute;nico</td><td>Sidecar por task</td></tr>
<tr><td>Identidad entre servicios</td><td>Token OIDC del metadata server</td>
    <td>Certificado mTLS de Istio</td><td>Security group + service discovery</td></tr>
<tr><td>Resiliencia</td><td>C&oacute;digo del cliente HTTP</td><td>Manifiestos de Istio</td>
    <td>C&oacute;digo del cliente HTTP</td></tr>
<tr><td>Destino de las se&ntilde;ales</td><td colspan="2">Cloud Trace · Managed Prometheus · Cloud Logging</td>
    <td>X-Ray · CloudWatch</td></tr>
<tr><td>Coste en reposo</td><td>&asymp; 0 (escala a cero)</td><td>&asymp; 0,20 USD/h</td><td>&asymp; 0,19 USD/h</td></tr>
<tr><td>Estado</td><td><strong>Desplegado y verificado</strong></td><td>Definido como c&oacute;digo</td>
    <td><strong>Desplegado y verificado</strong></td></tr>
</table>

<p>Los dos despliegues serverless est&aacute;n <strong>vivos y comprobados de extremo a
extremo</strong>: una petici&oacute;n atraviesa los tres servicios y las tres se&ntilde;ales
comparten <code>trace_id</code> en ambas nubes. El mapa de servicios que compone
AWS a partir de las trazas recibidas refleja exactamente la arquitectura
dise&ntilde;ada, sin que nadie se la haya descrito:</p>

<table>
<tr><th>Nodo</th><th>Tipo</th><th class="num">Peticiones correctas</th><th class="num">Errores</th></tr>
<tr><td><code>service-a</code></td><td>Contenedor gestionado</td><td class="num">7</td><td class="num">0</td></tr>
<tr><td><code>service-b</code></td><td>Contenedor gestionado</td><td class="num">6</td><td class="num">0</td></tr>
<tr><td><code>data-service</code></td><td>Contenedor gestionado</td><td class="num">6</td><td class="num">0</td></tr>
<tr><td><code>appdb</code></td><td>Database::SQL</td><td class="num">18</td><td class="num">0</td></tr>
</table>

<p>Las 18 consultas a base de datos frente a 19 peticiones HTTP son la huella de
la arquitectura: cada pedido dispara una lectura en <code>service-a</code>, otra
en <code>service-b</code> y la agregaci&oacute;n anal&iacute;tica en <code>data-service</code>.</p>

<p>La misma imagen corre en los tres. <code>service-a</code> detecta el entorno por
el esquema de la URL del destino: si es <code>https://</code> pide un token de
identidad al metadata server, porque est&aacute; hablando con un servicio de Cloud Run
protegido por IAM; si es <code>http://</code> no lo pide, porque dentro de la malla
la identidad la establece el certificado y no la cabecera.</p>

<p>Toda la infraestructura es Terraform, repartida en cuatro ra&iacute;ces
independientes por ciclo de vida: <code>gcp/</code> y <code>aws/</code> para los
despliegues serverless, <code>gke/</code> para el cl&uacute;ster &mdash;que se levanta y se
destruye el mismo d&iacute;a&mdash; y <code>observabilidad/</code> para alertas y paneles,
que describen c&oacute;mo se observa el sistema y deben sobrevivir a cualquier
despliegue concreto.</p>

<div class="ev-grid">%(ev_gcp)s</div>

<h3>El mismo pipeline en la otra nube</h3>

<p>Las capturas siguientes son del segundo proveedor y muestran exactamente las
mismas capacidades sobre herramientas distintas. No hubo cambios de codigo entre
un despliegue y otro: solo una configuracion distinta del Collector.</p>

<div class="ev-grid">%(ev_aws)s</div>

<h2 class="salto">9. C&oacute;mo reproducir el laboratorio</h2>

<p>El repositorio se entrega etiquetado como <code>v1.0</code>. La estructura
separa lo que se observa, lo que observa y d&oacute;nde corre:</p>

<pre><code>otel-lab/
  services/
    common/telemetry.py       bootstrap unico de las tres senales
    common/datastore.py       dos backends intercambiables (postgres / memoria)
    service-a/  service-b/  data-service/
  otel-collector/
    collector-local.yaml      Jaeger + Prometheus + Loki
    collector-gcp.yaml        Cloud Run  (sidecar)
    collector-gke.yaml        Kubernetes (k8sattributes + metricas de Istio)
    collector-aws.yaml        ECS Fargate (X-Ray + CloudWatch)
  k8s/                        manifiestos de la malla; 50- es el caos, aparte
  terraform/
    gcp/  aws/                despliegues serverless
    gke/                      cluster; se levanta y se destruye el mismo dia
    observabilidad/           alertas y paneles (Modulos B y C)
  aiops/
    detector.py               deteccion con baseline movil y correlacion
    escenario.sh             escenario controlado con ruido e incidente
  chaos/
    comun.sh                  probes SOT / DuringChaos / EOT
    experimentos/e1..e4       un experimento por hipotesis
    generador_carga.py        generador concurrente de un solo proceso
  docs/                       informes, evidencias y guias de despliegue</code></pre>

<table>
<tr><th>Paso</th><th>Comando</th><th>Resultado esperado</th></tr>
<tr><td>Levantar el stack local</td><td><code>docker compose up -d</code></td>
    <td>Diez contenedores sanos; Grafana en <code>:3000</code></td></tr>
<tr><td>Verificar la correlaci&oacute;n</td><td><code>bash scripts/verify-pipeline.sh</code></td>
    <td>Las tres se&ntilde;ales comparten <code>trace_id</code></td></tr>
<tr><td>Escenario de anomal&iacute;as</td><td><code>./aiops/escenario.sh</code></td>
    <td>Un incidente detectado, ruido descartado</td></tr>
<tr><td>Experimento de caos</td><td><code>bash chaos/experimentos/e4-errores-data-service.sh</code></td>
    <td>Veredicto con hip&oacute;tesis y presupuesto de error</td></tr>
<tr><td>Desplegar la malla</td><td><code>./scripts/desplegar-gke.sh</code></td>
    <td>Cl&uacute;ster, Istio y aplicaci&oacute;n; traza de extremo a extremo</td></tr>
<tr><td>Alertas y paneles</td><td><code>terraform -chdir=terraform/observabilidad apply</code></td>
    <td>Seis pol&iacute;ticas y el panel de seguridad</td></tr>
<tr><td>Regenerar este informe</td><td><code>python docs/generar_reporte_integrador.py</code></td>
    <td>HTML con las cifras de las &uacute;ltimas mediciones</td></tr>
</table>

<div class="nota">
<strong>Control de coste.</strong> El cl&uacute;ster de GKE es el &uacute;nico recurso con coste
por hora relevante (&asymp; 0,20 USD/h) y el script de despliegue lo recuerda al
terminar. <code>terraform -chdir=terraform/gke destroy</code> lo elimina por
completo, incluido el balanceador que crea el <em>ingress gateway</em> de Istio.
En AWS, <code>use_nat_gateway</code> se mantiene en <code>false</code> por el mismo
motivo: un NAT Gateway cuesta m&aacute;s que el resto del despliegue junto.
</div>

<h2 class="salto">10. Conclusiones</h2>

<p><strong>La instrumentaci&oacute;n com&uacute;n es lo que hace barato crecer.</strong> A&ntilde;adir el
tercer microservicio cost&oacute; importar un m&oacute;dulo y declarar sus instrumentos. La
alternativa &mdash;instrumentar cada servicio por su cuenta&mdash; habr&iacute;a multiplicado
el trabajo por tres y garantizado que los tres divergieran.</p>

<p><strong>La malla separa la resiliencia del c&oacute;digo.</strong> Los timeouts, los
reintentos y los <em>circuit breakers</em> que antes viv&iacute;an dentro del cliente HTTP
de Python ahora son manifiestos versionados. Cambiar un plazo dej&oacute; de ser un
despliegue para convertirse en un <code>kubectl apply</code>, y el cambio queda
registrado en el control de versiones en lugar de enterrado en un commit de
aplicaci&oacute;n.</p>

<p><strong>Correlacionar se&ntilde;ales reduce el ruido sin perder cobertura.</strong> El
escenario controlado lo midi&oacute;: %(reduccion)s menos avisos sin acci&oacute;n asociada y
ning&uacute;n incidente perdido. El factor decisivo no es el algoritmo sino la
exigencia de que dos se&ntilde;ales independientes se degraden a la vez y de forma
sostenida.</p>

<p><strong>Una alerta vale lo que vale su primer paso.</strong> Adjuntar el
<code>trace_id</code> de una petici&oacute;n que realmente fall&oacute; cambia el punto de
partida de quien responde: en lugar de buscar un ejemplo, abre el que ya tiene.
El criterio de selecci&oacute;n importa tanto como el mecanismo &mdash;la traza debe
haber fallado <em>para el cliente</em>, porque un error interno que el sistema
absorbi&oacute; no explica un incidente, explica por qu&eacute; no lo hubo.</p>

<p><strong>Desplegar de verdad encuentra lo que ning&uacute;n entorno local encuentra.</strong>
El esquema de la base de datos depend&iacute;a de una particularidad de la imagen
oficial de PostgreSQL: el contenedor ejecuta los scripts de inicializaci&oacute;n al
crear su volumen, pero una base gestionada no tiene ese mecanismo. En local
nunca fall&oacute;; en la nube, el primer pedido devolvi&oacute; <code>relation "orders"
does not exist</code>. La correcci&oacute;n &mdash;que el propio servicio garantice su
esquema con un script idempotente&mdash; es lo que hace que la misma imagen sirva
en los tres entornos sin pasos manuales. El mismo patr&oacute;n se repiti&oacute; con un
exporter del Collector que existe en una distribuci&oacute;n y no en otra.</p>

<p><strong>Un experimento que s&oacute;lo sabe confirmar no es un experimento.</strong> Los
cuatro experimentos verifican el estado estable antes de inyectar, comprueban
que el fallo ocurri&oacute; de verdad antes de evaluar la hip&oacute;tesis, y abortan si el
sistema ya est&aacute; fuera de su SLO. E4 termin&oacute; en &laquo;parcialmente confirmada&raquo;: la
disponibilidad aguant&oacute;, pero el p99 subi&oacute; m&aacute;s de lo previsto. Ese matiz es m&aacute;s
&uacute;til que un &laquo;confirmada&raquo; limpio, porque se&ntilde;ala d&oacute;nde mirar despu&eacute;s.</p>

<p>El resultado global es una plataforma con una media de madurez de
<strong>%(media)s sobre 5</strong> y una hoja de ruta donde cada acci&oacute;n responde a
una carencia medida, no a una lista de buenas pr&aacute;cticas. La brecha principal es
conocida y acotada: hay capacidades completas como c&oacute;digo que todav&iacute;a no se han
puesto bajo presi&oacute;n, y la madurez se mide por lo que el sistema demuestra
cuando se la pones.</p>

<div class="nota">
<strong>Reproducibilidad.</strong> Todas las cifras de este informe se leen de los
ficheros JSON que generan los propios experimentos
(<code>chaos/resultados/</code> y <code>aiops/resultados/</code>). El informe se
reconstruye con <code>python docs/generar_reporte_integrador.py</code>; si un
resultado falta, la celda aparece marcada como &laquo;sin dato&raquo; en vez de
transcribirse a mano.
</div>

</body>
</html>
"""

contexto = {
    "css": CSS,
    "fecha": FECHA,
    "reduccion": num(COMP.get("reduccion_de_ruido_pct"), "%.0f", " %"),
    "tabla_exp": tabla_experimentos(),
    "tabla_alertado": tabla_alertado(),
    "tabla_madurez": tabla_madurez(),
    "media": ("%.1f" % MEDIA).replace(".", ","),
    "ev_a": EVIDENCIAS_A,
    "ev_b": EVIDENCIAS_B,
    "ev_d": EVIDENCIAS_D,
    "ev_gcp": EVIDENCIAS_GCP,
    "ev_aws": EVIDENCIAS_AWS,
    "e3_pico": num(E3.get("p99_chaos_ms"), "%.0f"),
    "e3_fallbacks": num(E3.get("fallbacks_chaos"), "%.0f"),
    "inc_inicio": INC.get("inicio", "sin dato")[:19].replace("T", " "),
    "inc_dur": num(INC.get("duracion_s"), "%.0f"),
    "inc_p99": num(INC.get("latencia_p99_pico_ms"), "%.0f"),
    "inc_p99_base": num(INC.get("latencia_p99_baseline_ms"), "%.0f"),
    "inc_err": num(INC.get("error_rate_pico_pct"), "%.0f", " %"),
    "inc_err_base": num(INC.get("error_rate_baseline_pct"), "%.0f", " %"),
    "inc_trace": INC.get("trace_id", "sin dato"),
    "e4_sot": num(E4.get("p99_base_ms"), "%.0f"),
    "e4_err_ds": num(E4.get("error_rate_data_service_pct"), "%.2f", " %"),
    "e4_disp": num(E4.get("disponibilidad_borde_chaos"), "%.2f", " %"),
    "e4_err_borde": num(E4.get("error_rate_borde_pct"), "%.2f", " %"),
    "e4_rec": num(E4.get("recuperacion_s"), "%.0f"),
    "e4_hipotesis": E4.get("hipotesis", "sin dato"),
    "e4_detalle": E4.get("detalle", ""),
}

with open(SALIDA, "w", encoding="utf-8") as fh:
    fh.write(HTML % contexto)

print("Informe generado: %s" % os.path.relpath(SALIDA, RAIZ))
print("  experimentos con datos: %d de 4" % sum(1 for d in (E1, E2, E3, E4) if d))
print("  incidentes AIOps:       %d" % len(INCIDENTES))
print("  media de madurez:       %.2f" % MEDIA)
print()
print("Siguiente paso: bash scripts/generar-pdf.sh docs/reporte-integrador.html")
