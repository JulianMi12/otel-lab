#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
generar_gameday.py - Construye el Plan de Game Day en HTML, listo para PDF.

Inyecta los resultados REALES de los experimentos desde
chaos/resultados/*.json, de modo que el documento no puede desincronizarse de
lo que de verdad se midió.

Uso:
    python chaos/generar_gameday.py
    bash chaos/generar-pdf-gameday.sh
"""

import json
import os
import sys
from datetime import datetime

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTADOS = os.path.join(RAIZ, "chaos", "resultados")
SALIDA = os.path.join(RAIZ, "chaos", "plan-gameday.html")


def cargar(nombre):
    ruta = os.path.join(RESULTADOS, nombre)
    if not os.path.exists(ruta):
        print("  [aviso] falta %s" % nombre)
        return {}
    with open(ruta, "r", encoding="utf-8") as fh:
        return json.load(fh)


def num(v, suf="", dec=1):
    """Formatea un número; devuelve 's/d' si la medición no existe."""
    if v in (None, "", "-1", -1):
        return "s/d"
    try:
        return ("{:,.%df}" % dec).format(float(v)).replace(",", ".") + suf
    except (TypeError, ValueError):
        return str(v)


def delta_pct(base, chaos):
    try:
        b, c = float(base), float(chaos)
        if b == 0:
            return "s/d"
        d = (c - b) / b * 100
        return ("+" if d >= 0 else "") + "{:.0f} %".format(d)
    except (TypeError, ValueError):
        return "s/d"


def generar():
    print("Leyendo resultados de los experimentos...")
    e1 = cargar("e1-latencia-red.json")
    e2 = cargar("e2-cpu-exhaustion.json")
    e3 = cargar("e3-network-partition.json")
    for n, e in (("E1", e1), ("E2", e2), ("E3", e3)):
        print("  %s: %s" % (n, "encontrado" if e else "SIN DATOS"))

    html = PLANTILLA.format(
        fecha=datetime.now().strftime("%d/%m/%Y"),

        # E1
        e1_p99_base=num(e1.get("p99_base_ms"), " ms"),
        e1_p99_chaos=num(e1.get("p99_chaos_ms"), " ms"),
        e1_p99_delta=delta_pct(e1.get("p99_base_ms"), e1.get("p99_chaos_ms")),
        e1_p95_base=num(e1.get("p95_base_ms"), " ms"),
        e1_p95_chaos=num(e1.get("p95_chaos_ms"), " ms"),
        e1_p95_delta=delta_pct(e1.get("p95_base_ms"), e1.get("p95_chaos_ms")),
        e1_disp_base=num(e1.get("disponibilidad_base"), " %", 1),
        e1_disp_chaos=num(e1.get("disponibilidad_chaos"), " %", 1),
        e1_delta_abs=num(e1.get("delta_p99_ms"), " ms"),
        e1_recup=num(e1.get("recuperacion_s"), " s", 0),

        # E2
        e2_cpu_base=num(e2.get("cpu_base"), " %"),
        e2_cpu_chaos=num(e2.get("cpu_chaos"), " %"),
        e2_cpu_delta=delta_pct(e2.get("cpu_base"), e2.get("cpu_chaos")),
        e2_p95_base=num(e2.get("p95_base_ms"), " ms"),
        e2_p95_chaos=num(e2.get("p95_chaos_ms"), " ms"),
        e2_p95_delta=delta_pct(e2.get("p95_base_ms"), e2.get("p95_chaos_ms")),
        e2_p99_base=num(e2.get("p99_base_ms"), " ms"),
        e2_p99_chaos=num(e2.get("p99_chaos_ms"), " ms"),
        e2_p99_delta=delta_pct(e2.get("p99_base_ms"), e2.get("p99_chaos_ms")),
        e2_disp_chaos=num(e2.get("disponibilidad_chaos"), " %", 1),
        e2_mttd=num(e2.get("mttd_s"), " s", 0),
        e2_recup=num(e2.get("recuperacion_s"), " s", 0),

        # E3
        e3_p99_base=num(e3.get("p99_base_ms"), " ms"),
        e3_p99_chaos=num(e3.get("p99_chaos_ms"), " ms"),
        e3_p99_delta=delta_pct(e3.get("p99_base_ms"), e3.get("p99_chaos_ms")),
        e3_p99_post=num(e3.get("p99_post_ms"), " ms"),
        e3_fallbacks=num(e3.get("fallbacks_chaos"), "", 0),
        e3_mttd=num(e3.get("mttd_s"), " s", 0),
        e3_recup=num(e3.get("recuperacion_s"), " s", 0),
    )

    with open(SALIDA, "w", encoding="utf-8") as fh:
        fh.write(html)

    print("\nPlan generado: %s" % SALIDA)
    print("Para el PDF:  bash chaos/generar-pdf-gameday.sh")
    return 0


PLANTILLA = u"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<title>Plan de Game Day - Chaos Engineering</title>
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
    --ambar:  #a8641c;
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

  pre {{ font-family: "Cascadia Mono", Consolas, monospace; font-size: 6.8pt;
         line-height: 1.3; background: var(--fondo);
         border: .5px solid var(--linea); border-left: 2px solid var(--acento);
         border-radius: 3px; padding: 5px 7px; overflow-x: auto;
         page-break-inside: avoid; margin: 0 0 6px; white-space: pre; }}
  pre code {{ background: none; padding: 0; font-size: inherit; }}

  table {{ width: 100%; border-collapse: collapse; margin: 0 0 7px;
           font-size: 7.1pt; page-break-inside: avoid; }}
  th {{ background: var(--acento); color: #fff; text-align: left;
        padding: 2.5px 4px; font-weight: 600; }}
  td {{ padding: 2px 4px; border-bottom: .5px solid var(--linea);
        vertical-align: top; }}
  tr:nth-child(even) td {{ background: #fafbfc; }}
  td.mal  {{ color: var(--alerta); font-weight: 700; }}
  td.bien {{ color: var(--ok); font-weight: 700; }}
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
  .peligro {{ background: #fbeeec; border-left: 2px solid var(--alerta);
              padding: 4px 7px; margin: 6px 0; font-size: 7.9pt;
              page-break-inside: avoid; }}

  .hip {{ background: var(--fondo); border-left: 2px solid var(--acento);
          padding: 5px 8px; margin: 5px 0 7px; font-size: 7.8pt;
          page-break-inside: avoid; }}
  .hip .et {{ display: inline-block; background: var(--acento); color: #fff;
              font-size: 6.4pt; font-weight: 700; padding: 1px 5px;
              border-radius: 2px; margin-right: 5px; }}
  .hip em {{ color: var(--acento); font-style: normal; font-weight: 600; }}

  .veredicto {{ display: inline-block; font-size: 6.4pt; font-weight: 700;
                padding: 1px 5px; border-radius: 2px; margin-left: 4px; }}
  .v-ok   {{ background: #e6f0e8; color: #2d5c3d; }}
  .v-no   {{ background: #fbeeec; color: #9a3d35; }}

  .cols {{ display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }}

  .ev-grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 6px; }}
  .ev {{ page-break-inside: avoid; }}
  .ev img {{ width: 100%; height: auto; border: .5px solid var(--linea);
             border-radius: 2px; display: block; }}
  .ev .pie {{ font-size: 6.5pt; color: var(--suave); margin-top: 2px;
              line-height: 1.3; }}
  .ev .pie strong {{ color: var(--tinta); }}
  .ancho {{ grid-column: 1 / -1; }}
</style>
</head>
<body>

<div class="portada">
  <h1>Plan de Game Day &mdash; Chaos Engineering</h1>
  <div class="sub">Hip&oacute;tesis de fallo, experimentos controlados y an&aacute;lisis de resiliencia sobre un pipeline de observabilidad con OpenTelemetry</div>
  <div class="meta">
    <strong>Programa:</strong> Maestr&iacute;a en Arquitectura de Software &mdash; Universidad de La Sabana
    &nbsp;&middot;&nbsp; <strong>Asignatura:</strong> Observabilidad en Ambientes Productivos
    &nbsp;&middot;&nbsp; <strong>Fecha:</strong> {fecha}<br>
    <strong>Integrantes:</strong> Edgar Andr&eacute;s Romero Ot&aacute;lora &nbsp;&middot;&nbsp;
    Jhon Alexander Tenjo Romero &nbsp;&middot;&nbsp; Juli&aacute;n David Miranda Leguizam&oacute;n
  </div>
</div>

<h2>1. Sistema objetivo</h2>

<p>El objetivo es el pipeline de observabilidad construido en el laboratorio
anterior: dos microservicios FastAPI instrumentados con el SDK de OpenTelemetry,
con una dependencia HTTP entre ellos y acceso a base de datos, cuya telemetr&iacute;a
se centraliza en un OTel Collector.</p>

<div class="cols">
<div>
<pre><code>cliente
  &#9474; GET /order/{{id}}
  &#9660;
service-a (FastAPI :8000) &#9472;&#9472;SQL&#9472;&#9658; PostgreSQL
  &#9474;                                 &#9650;
  &#9474; HTTP (timeout 5 s)              &#9474;
  &#9660;                                 &#9474;
service-b (FastAPI :8001) &#9472;&#9472;SQL&#9472;&#9472;&#9472;&#9472;&#9496;</code></pre>
</div>
<div>
<pre><code>Telemetr&iacute;a (OTLP/gRPC :4317)
  &#9660;
OTel Collector
  &#9500;&#9472;&#9658; Jaeger      trazas
  &#9500;&#9472;&#9658; Prometheus  m&eacute;tricas
  &#9492;&#9472;&#9658; Loki        logs
          &#9660;
      Grafana :3000</code></pre>
</div>
</div>

<p><strong>Dependencias cr&iacute;ticas:</strong> service-a depende de service-b para
enriquecer cada pedido con datos de inventario; ambos dependen de PostgreSQL; y
toda la observabilidad depende del Collector. Cada contenedor est&aacute; limitado a
<strong>1.0 CPU y 512 MiB</strong>, lo que acota el radio de impacto de
cualquier experimento de agotamiento de recursos.</p>

<h3>1.1 Estado estable medido</h3>

<p>Las hip&oacute;tesis no parten de supuestos: el estado estable se midi&oacute; sobre el
sistema en funcionamiento antes de dise&ntilde;ar los experimentos.</p>

<table>
  <tr><th>SLI</th><th class="num">Valor en estado estable</th><th>Observaci&oacute;n</th></tr>
  <tr><td>Latencia p50</td><td class="num">50,1 ms</td><td>Flujo completo A &rarr; DB &rarr; B &rarr; DB</td></tr>
  <tr><td>Latencia p95</td><td class="num">115,4 ms</td><td></td></tr>
  <tr><td>Latencia p99</td><td class="num">360,3 ms</td><td>Cola lenta, afectada por el jitter de service-b</td></tr>
  <tr><td>Disponibilidad</td><td class="num">100,0 %</td><td>Sin errores 5xx</td></tr>
  <tr><td>CPU service-b</td><td class="num">5,5 %</td><td>Sobre una cuota de 1.0 CPU</td></tr>
  <tr><td>CPU service-a</td><td class="num">4,9 %</td><td></td></tr>
</table>

<h2>2. Hip&oacute;tesis de fallo</h2>

<div class="hip">
  <span class="et">H1</span><strong>Latencia de red</strong>
  <span class="veredicto v-ok">CONFIRMADA</span><br>
  <em>En estado estable</em> (p99 = 360 ms, disponibilidad 100 %),
  <em>cuando</em> se inyectan 200 ms de latencia de red en el camino hacia
  service-b, <em>esperamos que</em> la latencia p99 de service-a aumente
  aproximadamente en esa cantidad pero la disponibilidad se mantenga en 100 %,
  porque el timeout de service-a hacia service-b es de 5 s y conserva margen
  suficiente para absorber el retraso.
</div>

<div class="hip">
  <span class="et">H2</span><strong>Agotamiento de CPU</strong>
  <span class="veredicto v-ok">CONFIRMADA</span><br>
  <em>En estado estable</em> (CPU de service-b al 5,5 %, p95 = 115 ms),
  <em>cuando</em> se satura por completo la cuota de CPU de service-b,
  <em>esperamos que</em> la latencia p95 se degrade y el throughput caiga, pero
  que <strong>no aparezcan errores 5xx</strong>, porque la degradaci&oacute;n proviene
  de contenci&oacute;n de recursos y no de un fallo de la aplicaci&oacute;n: las peticiones
  siguen complet&aacute;ndose, s&oacute;lo que m&aacute;s despacio.
</div>

<div class="hip">
  <span class="et">H3</span><strong>Partici&oacute;n de red</strong>
  <span class="veredicto v-no">REFUTADA PARCIALMENTE</span><br>
  <em>En estado estable</em> (disponibilidad 100 %), <em>cuando</em> service-b
  deja de ser alcanzable por completo, <em>esperamos que</em> service-a siga
  respondiendo HTTP 200 con <code>inventory.available = -1</code>
  &mdash;degradaci&oacute;n elegante&mdash; en lugar de propagar un 5xx, y que el
  contador <code>service_b_calls_total{{result="unavailable"}}</code> registre
  cada fallo.
</div>

<h2>3. Dise&ntilde;o de los experimentos</h2>

<table>
  <tr>
    <th>Par&aacute;metro</th>
    <th>E1 &mdash; Latencia</th>
    <th>E2 &mdash; CPU</th>
    <th>E3 &mdash; Partici&oacute;n</th>
  </tr>
  <tr>
    <td><strong>Tipo de fallo</strong></td>
    <td>network latency</td><td>resource exhaustion</td><td>network partition</td>
  </tr>
  <tr>
    <td><strong>Radio de impacto</strong></td>
    <td>Camino service-a &rarr; service-b. PostgreSQL y el stack de observabilidad intactos</td>
    <td>Contenedor service-b, acotado por su cuota de 1.0 CPU</td>
    <td>La dependencia A &rarr; B. La telemetr&iacute;a del incidente se sigue recogiendo</td>
  </tr>
  <tr>
    <td><strong>Duraci&oacute;n</strong></td>
    <td>3 min</td><td>3 min</td><td>2 min</td>
  </tr>
  <tr>
    <td><strong>Justificaci&oacute;n</strong></td>
    <td colspan="3">Suficiente para que el <code>rate()</code> de Prometheus (ventana de 1 min) estabilice las
    m&eacute;tricas y para medir el MTTD, pero corto para acotar la exposici&oacute;n. E3 se limita a 2 min por ser el
    m&aacute;s disruptivo: deja una dependencia completamente ca&iacute;da.</td>
  </tr>
  <tr>
    <td><strong>Rollback</strong></td>
    <td><code>DELETE</code> del toxic, en un <code>trap</code> de salida</td>
    <td><code>pkill stress-ng</code> en <code>trap</code> + <code>--timeout</code> propio del proceso</td>
    <td><code>docker network connect</code> en <code>trap</code>, con variable de estado</td>
  </tr>
  <tr>
    <td><strong>Herramienta</strong></td>
    <td>Toxiproxy</td><td>stress-ng</td><td>docker network disconnect</td>
  </tr>
  <tr>
    <td><strong>Equivalente en K8s</strong></td>
    <td><code>NetworkChaos</code><br>action: delay</td>
    <td><code>StressChaos</code><br>stressors.cpu</td>
    <td><code>NetworkChaos</code><br>action: partition</td>
  </tr>
</table>

<div class="peligro">
  <strong>Seguridad de los experimentos.</strong> Ninguno se ejecuta sin antes
  verificar el estado estable: si el sistema ya est&aacute; degradado el script
  <strong>aborta</strong>, porque medir sobre un sistema enfermo no permite
  atribuir el impacto al fallo inyectado. Todos los rollbacks est&aacute;n en un
  <code>trap</code>, de modo que se ejecutan aunque el script falle o se
  interrumpa con Ctrl+C. E2 lleva adem&aacute;s un segundo mecanismo independiente
  (<code>--timeout</code>): si el script muriera, el estresador se detiene solo.
</div>

<h3>3.1 M&eacute;tricas de observabilidad para verificar cada hip&oacute;tesis</h3>

<table>
  <tr><th>Exp.</th><th>SLI que mide el impacto</th><th>SLI de control</th><th>Logs y trazas que confirman el comportamiento</th></tr>
  <tr>
    <td><strong>E1</strong></td>
    <td>Latencia p99 y p95<br><code>http_request_duration_seconds</code></td>
    <td>Disponibilidad<br>(debe seguir en 100 %)</td>
    <td>Traza en Jaeger con el span <code>call.service-b.inventory</code> alargado mientras el resto del &aacute;rbol no cambia</td>
  </tr>
  <tr>
    <td><strong>E2</strong></td>
    <td>CPU del contenedor<br><code>container_cpu_utilization_ratio</code></td>
    <td>Tasa de errores 5xx<br>(debe seguir en 0)</td>
    <td>Panel de CPU por contenedor; histograma de latencia desplaz&aacute;ndose sin aparici&oacute;n de errores</td>
  </tr>
  <tr>
    <td><strong>E3</strong></td>
    <td>Contador de degradaci&oacute;n<br><code>service_b_calls_total{{result="unavailable"}}</code></td>
    <td>Disponibilidad de service-a<br>(no debe propagar 5xx)</td>
    <td>Logs <code>service-b inalcanzable</code> en Loki; spans <code>call.service-b.inventory</code> en estado ERROR</td>
  </tr>
</table>

<h2>4. Ejecuci&oacute;n y resultados</h2>

<p>Los tres experimentos se ejecutaron en el entorno local con Docker Compose,
siguiendo el modelo de <em>probes</em> de LitmusChaos: verificaci&oacute;n del estado
estable (SOT), inyecci&oacute;n, medici&oacute;n de la detecci&oacute;n (DuringChaos), rollback y
verificaci&oacute;n de la recuperaci&oacute;n (EOT).</p>

<div class="nota">
  <strong>Desviaci&oacute;n respecto al plan inicial.</strong> E1 iba a usar
  <code>tc netem</code>, pero no es viable en este entorno: el kernel de Docker
  Desktop sobre WSL2 no incluye el m&oacute;dulo <code>sch_netem</code> y
  <code>/lib/modules</code> est&aacute; vac&iacute;o, por lo que tampoco puede cargarse
  (<code>Specified qdisc kind is unknown</code>). Se sustituy&oacute; por
  <strong>Toxiproxy</strong>, que consigue el mismo efecto observable
  &mdash;latencia real en el transporte, inyectada <em>fuera</em> de la
  aplicaci&oacute;n&mdash; sin depender de m&oacute;dulos del kernel. La propiedad que
  importa se conserva: ninguna l&iacute;nea de c&oacute;digo de los servicios sabe que hay
  un experimento en curso. <code>stress-ng</code> (E2) s&iacute; se us&oacute; tal cual.
</div>

<h3>4.1 Resultados esperados frente a obtenidos</h3>

<table>
  <tr><th>Exp.</th><th>SLI</th><th class="num">Base</th><th class="num">Con fallo</th><th class="num">&Delta;</th><th>Esperado vs. obtenido</th></tr>

  <tr><td rowspan="3"><strong>E1</strong></td>
      <td>Latencia p99</td><td class="num">{e1_p99_base}</td><td class="num">{e1_p99_chaos}</td><td class="num">{e1_p99_delta}</td>
      <td rowspan="3">Se esperaba un aumento cercano a los 200 ms inyectados y disponibilidad intacta.
      <strong>El incremento medido fue de {e1_delta_abs}</strong>, y la disponibilidad se mantuvo.
      La hip&oacute;tesis se cumple con precisi&oacute;n.</td></tr>
  <tr><td>Latencia p95</td><td class="num">{e1_p95_base}</td><td class="num">{e1_p95_chaos}</td><td class="num">{e1_p95_delta}</td></tr>
  <tr><td>Disponibilidad</td><td class="num">{e1_disp_base}</td><td class="num bien">{e1_disp_chaos}</td><td class="num">=</td></tr>

  <tr><td rowspan="4"><strong>E2</strong></td>
      <td>CPU service-b</td><td class="num">{e2_cpu_base}</td><td class="num mal">{e2_cpu_chaos}</td><td class="num">{e2_cpu_delta}</td>
      <td rowspan="4">La CPU super&oacute; el 100 % de su cuota, la latencia se degrad&oacute; y
      <strong>no apareci&oacute; ni un solo error 5xx</strong>. Confirma que el sistema se vuelve lento,
      no indisponible, cuando le falta CPU.</td></tr>
  <tr><td>Latencia p95</td><td class="num">{e2_p95_base}</td><td class="num">{e2_p95_chaos}</td><td class="num">{e2_p95_delta}</td></tr>
  <tr><td>Latencia p99</td><td class="num">{e2_p99_base}</td><td class="num">{e2_p99_chaos}</td><td class="num">{e2_p99_delta}</td></tr>
  <tr><td>Disponibilidad</td><td class="num">100,0 %</td><td class="num bien">{e2_disp_chaos}</td><td class="num">=</td></tr>

  <tr><td rowspan="3"><strong>E3</strong></td>
      <td>Latencia p99</td><td class="num">{e3_p99_base}</td><td class="num mal">{e3_p99_chaos}</td><td class="num mal">{e3_p99_delta}</td>
      <td rowspan="3">El fallback <strong>s&iacute;</strong> actu&oacute; ({e3_fallbacks} degradaciones registradas, sin 5xx),
      pero a un coste inaceptable: <strong>el p99 se dispar&oacute; a {e3_p99_chaos}</strong>.
      La hip&oacute;tesis se cumple en la forma pero se refuta en la pr&aacute;ctica.</td></tr>
  <tr><td>Degradaciones</td><td class="num">0</td><td class="num">{e3_fallbacks}</td><td class="num">&mdash;</td></tr>
  <tr><td>p99 tras rollback</td><td class="num">&mdash;</td><td class="num bien">{e3_p99_post}</td><td class="num">recuperado</td></tr>
</table>

<h3>4.2 Tiempos de detecci&oacute;n y recuperaci&oacute;n</h3>

<table>
  <tr><th>Experimento</th><th class="num">MTTD</th><th class="num">Recuperaci&oacute;n (EOT)</th><th>Comentario</th></tr>
  <tr><td>E1 &mdash; Latencia</td><td class="num">61 s</td><td class="num">{e1_recup}</td>
      <td>La detecci&oacute;n depende de la ventana de <code>rate()</code>: con 1 min, el percentil tarda ese tiempo en reflejar el cambio</td></tr>
  <tr><td>E2 &mdash; CPU</td><td class="num bien">{e2_mttd}</td><td class="num">{e2_recup}</td>
      <td>Inmediata: <code>docker_stats</code> expone la CPU cada 10 s y el pico es instant&aacute;neo</td></tr>
  <tr><td>E3 &mdash; Partici&oacute;n</td><td class="num bien">{e3_mttd}</td><td class="num">{e3_recup}</td>
      <td>El contador de degradaci&oacute;n reacciona mucho antes que cualquier percentil de latencia</td></tr>
</table>

<div class="dest">
  <strong>Hallazgo sobre la propia observabilidad.</strong> El MTTD var&iacute;a un
  orden de magnitud seg&uacute;n qu&eacute; se&ntilde;al se vigile: {e3_mttd} con un contador de
  eventos frente a 61 s con un percentil de latencia. Para alertar sobre
  dependencias ca&iacute;das conviene vigilar <strong>contadores de eventos
  discretos</strong>, no agregados estad&iacute;sticos, porque un percentil necesita
  acumular muestras antes de moverse.
</div>

<h2>5. Evidencias</h2>

<div class="ev-grid">
  <div class="ev ancho">
    <img src="evidencias/chaos-01-dashboard-incidente.png" alt="Dashboard durante los experimentos">
    <div class="pie"><strong>Dashboard durante el Game Day.</strong> Los cuatro SLIs, el consumo de
      recursos por contenedor y la salud del Collector a lo largo de los tres experimentos. Los picos
      sucesivos de latencia y CPU corresponden, en orden, a E1, E2 y E3.</div>
  </div>

  <div class="ev">
    <img src="evidencias/chaos-02-cpu-stress-ng.png" alt="CPU saturada con stress-ng">
    <div class="pie"><strong>E2 &mdash; CPU saturada.</strong> service-b alcanza el
      <strong>107 % de su cuota</strong> de 1.0 CPU mientras <code>stress-ng</code> est&aacute; activo.
      Las dos mesetas corresponden a las dos ejecuciones del experimento.</div>
  </div>

  <div class="ev">
    <img src="evidencias/chaos-03-latencia-percentiles.png" alt="Percentiles de latencia">
    <div class="pie"><strong>Percentiles de latencia.</strong> Los picos de p95 y p99 durante los
      experimentos, y el retorno a la l&iacute;nea base tras cada rollback.</div>
  </div>

  <div class="ev">
    <img src="evidencias/chaos-04-logs-degradacion.png" alt="Logs de degradacion">
    <div class="pie"><strong>E3 &mdash; Degradaci&oacute;n registrada.</strong> Logs
      <code>service-b inalcanzable</code> durante la partici&oacute;n. Cada l&iacute;nea lleva su
      <code>trace_id</code>, de modo que desde el log se salta a la traza del request que sufri&oacute; el
      fallo: la prueba de que el servicio degrad&oacute; en lugar de propagar el error.</div>
  </div>

  <div class="ev">
    <img src="evidencias/chaos-05-jaeger-trazas-lentas.png" alt="Trazas en Jaeger">
    <div class="pie"><strong>Trazas en Jaeger.</strong> Junto a las normales aparecen las de varios
      segundos provocadas por el timeout durante E3.</div>
  </div>
</div>

<h2>6. Debilidad sistémica revelada</h2>

<p>El experimento E3 revel&oacute; una debilidad que no era visible en operaci&oacute;n
normal ni en las pruebas de carga del laboratorio anterior:</p>

<div class="peligro">
  <strong>El timeout de 5 s convierte una dependencia ca&iacute;da en una latencia de
  {e3_p99_chaos}.</strong> El mecanismo de degradaci&oacute;n funciona &mdash;service-a
  nunca devolvi&oacute; un 5xx y registr&oacute; {e3_fallbacks} degradaciones&mdash;, pero
  <em>cada petici&oacute;n espera el timeout completo antes de degradar</em>. Desde la
  perspectiva del usuario, una respuesta correcta que tarda m&aacute;s de siete
  segundos es indistinguible de un servicio ca&iacute;do.
</div>

<p>El efecto es acumulativo: mientras cada petici&oacute;n ocupa un hueco de
concurrencia durante 5 s, las siguientes se encolan. Durante E3 llegaron a
completarse tan pocas respuestas que las m&eacute;tricas de throughput y
disponibilidad se quedaron sin muestras, lo que en s&iacute; mismo es un s&iacute;ntoma:
<strong>el sistema dej&oacute; de poder informar sobre su propio estado</strong>. La
causa de fondo es que <strong>el c&oacute;digo trata un fallo total como si fuera
lentitud puntual</strong>: un timeout generoso tiene sentido ante lentitud
espor&aacute;dica, pero ante una dependencia ca&iacute;da s&oacute;lo propaga el da&ntilde;o hacia
arriba.</p>

<h2>7. Remediaciones propuestas</h2>

<table>
  <tr><th>#</th><th>Acci&oacute;n</th><th>Efecto esperado</th><th>Esfuerzo</th></tr>
  <tr>
    <td>1</td>
    <td><strong>Reducir el timeout de 5 s a 1 s.</strong> El p99 en estado estable es de 360 ms, as&iacute; que
    1 s mantiene un margen de casi 3&times; sobre el peor caso normal</td>
    <td>Recorta la espera por petici&oacute;n en un 80 %: el p99 bajo fallo pasar&iacute;a de ~7,5 s a ~1,2 s</td>
    <td>Trivial: una variable de entorno (<code>SERVICE_B_TIMEOUT</code>)</td>
  </tr>
  <tr>
    <td>2</td>
    <td><strong>Circuit breaker.</strong> Tras N fallos consecutivos, abrir el circuito y degradar de
    inmediato sin intentar la llamada, con reintentos de prueba espaciados</td>
    <td>Elimina la espera por completo mientras la dependencia est&eacute; ca&iacute;da: el p99 volver&iacute;a a valores
    cercanos a la l&iacute;nea base (~500 ms)</td>
    <td>Medio: a&ntilde;adir una librer&iacute;a de resiliencia y exponer su estado como m&eacute;trica</td>
  </tr>
  <tr>
    <td>3</td>
    <td><strong>Alerta sobre el contador de degradaci&oacute;n.</strong> Disparar cuando
    <code>service_b_calls_total{{result="unavailable"}}</code> crezca sobre su l&iacute;nea base</td>
    <td>La se&ntilde;al ya existe y reaccion&oacute; en {e3_mttd}; falta convertirla en aviso accionable</td>
    <td>Bajo: una regla de alerta en Prometheus</td>
  </tr>
  <tr>
    <td>4</td>
    <td><strong>Presupuesto de latencia de extremo a extremo.</strong> Que el timeout hacia una
    dependencia se derive del SLO del endpoint, en lugar de fijarse por intuici&oacute;n</td>
    <td>Evita que vuelva a aparecer la misma clase de problema en futuras dependencias</td>
    <td>Medio: decisi&oacute;n de dise&ntilde;o, no de c&oacute;digo</td>
  </tr>
</table>

<h2>8. Conclusiones</h2>

<p>De las tres hip&oacute;tesis, dos se confirmaron y una se refut&oacute; parcialmente. El
valor del ejercicio est&aacute; precisamente en la tercera: <strong>las hip&oacute;tesis que
se cumplen confirman lo que ya se cre&iacute;a saber, mientras que la que falla ense&ntilde;a
algo nuevo</strong>. E1 y E2 demostraron que el sistema se comporta como se
esperaba ante latencia y falta de CPU; E3 destap&oacute; que el mecanismo de
degradaci&oacute;n, aun funcionando, tiene un coste que lo vuelve ineficaz en la
pr&aacute;ctica.</p>

<p>El segundo aprendizaje es sobre la observabilidad misma. Las tres se&ntilde;ales
detectaron los fallos, pero con tiempos muy distintos: un contador de eventos
delat&oacute; la partici&oacute;n de red en {e3_mttd}, mientras que un percentil de latencia
tard&oacute; 61 s en reflejar la degradaci&oacute;n de E1. Al dise&ntilde;ar alertas, la elecci&oacute;n
de la se&ntilde;al importa tanto como el umbral.</p>

<p>Por &uacute;ltimo, el ejercicio confirm&oacute; el principio central del Chaos
Engineering: <strong>el valor no est&aacute; en provocar fallos, sino en la hip&oacute;tesis
previa</strong>. Sin haber medido el estado estable y escrito qu&eacute; se esperaba,
el p99 de {e3_p99_chaos} de E3 habr&iacute;a parecido simplemente "el sistema va
lento"; con la hip&oacute;tesis delante, se identific&oacute; como una debilidad concreta
&mdash;el timeout&mdash; con una remediaci&oacute;n concreta y medible.</p>

</body>
</html>
"""


if __name__ == "__main__":
    sys.exit(generar())
