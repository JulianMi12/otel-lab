#!/usr/bin/env python3
"""
analyze_overhead.py - Analisis comparativo del overhead de OpenTelemetry.

Combina dos fuentes de evidencia para construir la tabla comparativa del
reporte tecnico:

    1. k6  -> latencia y throughput medidos desde el CLIENTE
              (benchmark/results/k6-baseline.json y k6-instrumented.json)
    2. Prometheus -> CPU y memoria medidos desde el HOST, a traves del
              receiver docker_stats del Collector

Medir la latencia desde el cliente y los recursos desde el host evita el sesgo
de pedirle al proceso instrumentado que se mida a si mismo.

Uso:
    python benchmark/analyze_overhead.py
    python benchmark/analyze_overhead.py --prometheus http://localhost:9090
"""

import argparse
import json
import os
import sys
from datetime import datetime

try:
    import urllib.request
    import urllib.parse
except ImportError:  # pragma: no cover
    print("Se requiere Python 3", file=sys.stderr)
    sys.exit(1)

RESULTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")

# Contenedores a comparar. docker_stats etiqueta cada serie con container.name.
CONTENEDORES = {
    "baseline": ["service-a-baseline", "service-b-baseline"],
    "instrumented": ["service-a", "service-b"],
}


# -----------------------------------------------------------------------------
# Consulta a Prometheus
# -----------------------------------------------------------------------------
def consultar_prometheus(base_url, query, timeout=15):
    """Ejecuta una query instantanea y devuelve la lista de resultados."""
    url = base_url.rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode(
        {"query": query}
    )
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:
        print("  [aviso] Prometheus no respondio: " + str(exc), file=sys.stderr)
        return []

    if payload.get("status") != "success":
        print("  [aviso] query fallida: " + query, file=sys.stderr)
        return []

    return payload.get("data", {}).get("result", [])


def metrica_por_contenedor(base_url, promql_template, contenedores, ventana="5m"):
    """
    Evalua una plantilla PromQL por contenedor y devuelve {contenedor: valor}.

    Se usa max_over_time sobre la ventana de la prueba en vez del valor
    instantaneo: el valor puntual dependeria del momento exacto del scrape.
    """
    valores = {}
    for nombre in contenedores:
        query = promql_template.format(contenedor=nombre, ventana=ventana)
        resultado = consultar_prometheus(base_url, query)
        if resultado:
            try:
                valores[nombre] = float(resultado[0]["value"][1])
            except (KeyError, IndexError, ValueError):
                valores[nombre] = None
        else:
            valores[nombre] = None
    return valores


def recolectar_recursos(base_url, ventana="10m"):
    """
    Obtiene CPU y memoria pico de cada contenedor durante la ventana indicada.

    Los nombres provienen del receiver docker_stats del Collector, ya
    normalizados por el exporter de Prometheus (puntos a guiones bajos, mas el
    sufijo de unidad que anade la convencion de OpenTelemetry):

        container.cpu.utilization    -> container_cpu_utilization_ratio
        container.memory.usage.total -> container_memory_usage_total_bytes

    El valor de CPU ya viene expresado en PORCENTAJE (96.0 = 96 %), no como
    fraccion entre 0 y 1, por lo que no se reescala.

    Se usa max by (container_name) porque al recrear un contenedor aparece una
    serie nueva con otro container_id: sin la agregacion se compararia contra
    la serie antigua de un contenedor que ya no existe.
    """
    recursos = {}

    for escenario, contenedores in CONTENEDORES.items():
        cpu = metrica_por_contenedor(
            base_url,
            'max(max_over_time(container_cpu_utilization_ratio'
            '{{container_name="{contenedor}"}}[{ventana}]))',
            contenedores,
            ventana,
        )
        cpu_prom = metrica_por_contenedor(
            base_url,
            'max(avg_over_time(container_cpu_utilization_ratio'
            '{{container_name="{contenedor}"}}[{ventana}]))',
            contenedores,
            ventana,
        )
        mem = metrica_por_contenedor(
            base_url,
            'max(max_over_time(container_memory_usage_total_bytes'
            '{{container_name="{contenedor}"}}[{ventana}]))',
            contenedores,
            ventana,
        )

        recursos[escenario] = {
            "cpu_pico_pct": cpu,
            "cpu_promedio_pct": cpu_prom,
            "memoria_pico_bytes": mem,
        }

    return recursos


# -----------------------------------------------------------------------------
# Lectura de los resultados de k6
# -----------------------------------------------------------------------------
def cargar_resultado_k6(escenario):
    ruta = os.path.join(RESULTS_DIR, "k6-" + escenario + ".json")
    if not os.path.exists(ruta):
        return None
    with open(ruta, "r", encoding="utf-8") as fh:
        return json.load(fh)


# -----------------------------------------------------------------------------
# Calculo del overhead
# -----------------------------------------------------------------------------
def delta_pct(base, nuevo):
    """Variacion porcentual; None si falta algun dato o la base es cero."""
    if base is None or nuevo is None or base == 0:
        return None
    return ((nuevo - base) / base) * 100.0


def fmt(valor, sufijo="", decimales=2):
    if valor is None:
        return "n/d"
    return ("{:." + str(decimales) + "f}").format(valor) + sufijo


def fmt_delta(valor):
    if valor is None:
        return "n/d"
    signo = "+" if valor >= 0 else ""
    return signo + "{:.2f}".format(valor) + " %"


def suma_segura(diccionario):
    """Suma ignorando los None; devuelve None si no hay ningun valor."""
    valores = [v for v in diccionario.values() if v is not None]
    return sum(valores) if valores else None


def construir_tabla(base, instr, recursos):
    filas = []

    # ── Latencia (medida por k6 desde el cliente) ────────────────────────────
    for etiqueta, clave in [
        ("Latencia media", "avg"),
        ("Latencia p95", "p95"),
        ("Latencia p99", "p99"),
    ]:
        b = base["latencia_ms"].get(clave) if base else None
        i = instr["latencia_ms"].get(clave) if instr else None
        filas.append(
            {
                "metrica": etiqueta,
                "unidad": "ms",
                "base": fmt(b, " ms"),
                "instrumentado": fmt(i, " ms"),
                "delta_abs": fmt(i - b, " ms") if (b is not None and i is not None) else "n/d",
                "delta_pct": fmt_delta(delta_pct(b, i)),
            }
        )

    # ── Throughput ───────────────────────────────────────────────────────────
    b_rps = base.get("rps_promedio") if base else None
    i_rps = instr.get("rps_promedio") if instr else None
    filas.append(
        {
            "metrica": "Throughput",
            "unidad": "req/s",
            "base": fmt(b_rps, " req/s"),
            "instrumentado": fmt(i_rps, " req/s"),
            "delta_abs": fmt(i_rps - b_rps, " req/s")
            if (b_rps is not None and i_rps is not None)
            else "n/d",
            "delta_pct": fmt_delta(delta_pct(b_rps, i_rps)),
        }
    )

    # ── CPU (medida por docker_stats via Collector) ──────────────────────────
    # docker_stats ya reporta la utilizacion en porcentaje: no se reescala.
    b_cpu = suma_segura(recursos["baseline"]["cpu_promedio_pct"])
    i_cpu = suma_segura(recursos["instrumented"]["cpu_promedio_pct"])
    filas.append(
        {
            "metrica": "CPU promedio (ambos servicios)",
            "unidad": "%",
            "base": fmt(b_cpu, " %"),
            "instrumentado": fmt(i_cpu, " %"),
            "delta_abs": fmt(i_cpu - b_cpu, " pp")
            if (b_cpu is not None and i_cpu is not None)
            else "n/d",
            "delta_pct": fmt_delta(delta_pct(b_cpu, i_cpu)),
        }
    )

    # ── Memoria ──────────────────────────────────────────────────────────────
    b_mem = suma_segura(recursos["baseline"]["memoria_pico_bytes"])
    i_mem = suma_segura(recursos["instrumented"]["memoria_pico_bytes"])
    b_mb = b_mem / (1024 * 1024) if b_mem else None
    i_mb = i_mem / (1024 * 1024) if i_mem else None
    filas.append(
        {
            "metrica": "Memoria pico (ambos servicios)",
            "unidad": "MiB",
            "base": fmt(b_mb, " MiB"),
            "instrumentado": fmt(i_mb, " MiB"),
            "delta_abs": fmt(i_mb - b_mb, " MiB")
            if (b_mb is not None and i_mb is not None)
            else "n/d",
            "delta_pct": fmt_delta(delta_pct(b_mb, i_mb)),
        }
    )

    return filas


def imprimir_tabla(filas):
    anchos = [32, 18, 18, 16, 12]
    cabecera = ["Metrica", "Sin OTel", "Con OTel", "Diferencia", "Overhead"]

    linea = "+".join("-" * (a + 2) for a in anchos)
    print("+" + linea + "+")
    print(
        "| "
        + " | ".join(c.ljust(a) for c, a in zip(cabecera, anchos))
        + " |"
    )
    print("+" + linea + "+")
    for f in filas:
        celdas = [
            f["metrica"],
            f["base"],
            f["instrumentado"],
            f["delta_abs"],
            f["delta_pct"],
        ]
        print("| " + " | ".join(c.ljust(a) for c, a in zip(celdas, anchos)) + " |")
    print("+" + linea + "+")


def escribir_markdown(filas, base, instr, ruta):
    with open(ruta, "w", encoding="utf-8") as fh:
        fh.write("# Analisis de overhead de OpenTelemetry\n\n")
        fh.write(
            "Generado el "
            + datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            + "\n\n"
        )

        fh.write("## Condiciones de la prueba\n\n")
        if base and instr:
            fh.write(
                "- Usuarios concurrentes: " + str(instr.get("vus_maximos")) + "\n"
            )
            fh.write(
                "- Duracion de la meseta: "
                + str(instr.get("duracion_meseta"))
                + "\n"
            )
            fh.write(
                "- Requests linea base: " + str(base.get("requests_totales")) + "\n"
            )
            fh.write(
                "- Requests instrumentado: "
                + str(instr.get("requests_totales"))
                + "\n"
            )
            fh.write(
                "- Limites por contenedor: 1.0 CPU / 512 MiB (identicos en ambos)\n"
            )
        fh.write("\n")

        fh.write("## Tabla comparativa\n\n")
        fh.write("| Metrica | Sin OTel | Con OTel | Diferencia | Overhead |\n")
        fh.write("|---|---|---|---|---|\n")
        for f in filas:
            fh.write(
                "| "
                + f["metrica"]
                + " | "
                + f["base"]
                + " | "
                + f["instrumentado"]
                + " | "
                + f["delta_abs"]
                + " | "
                + f["delta_pct"]
                + " |\n"
            )
        fh.write("\n")

        if instr:
            con_trace = instr.get("respuestas_con_trace_id") or 0
            total = instr.get("requests_totales") or 0
            fh.write("## Verificacion de correlacion\n\n")
            fh.write(
                "Respuestas con trace_id valido (32 hex, W3C): "
                + str(con_trace)
                + "\n\n"
            )
            if total:
                fh.write(
                    "Esto representa el "
                    + "{:.1f}".format(100.0 * con_trace / total)
                    + " % de los requests del escenario instrumentado "
                    + "(los listados y los 404 no devuelven trace_id).\n"
                )

    print("\nReporte escrito en: " + ruta)


def main():
    parser = argparse.ArgumentParser(
        description="Compara el rendimiento con y sin instrumentacion OTel"
    )
    parser.add_argument(
        "--prometheus",
        default=os.getenv("PROMETHEUS_URL", "http://localhost:9090"),
        help="URL base de Prometheus",
    )
    parser.add_argument(
        "--ventana",
        default="10m",
        help="Ventana temporal para las metricas de recursos (default: 10m)",
    )
    parser.add_argument(
        "--salida",
        default=os.path.join(RESULTS_DIR, "overhead.md"),
        help="Ruta del reporte Markdown de salida",
    )
    args = parser.parse_args()

    print("Leyendo resultados de k6 desde " + RESULTS_DIR)
    base = cargar_resultado_k6("baseline")
    instr = cargar_resultado_k6("instrumented")

    if not base:
        print(
            "  [falta] k6-baseline.json - ejecuta primero el escenario de linea base",
            file=sys.stderr,
        )
    if not instr:
        print(
            "  [falta] k6-instrumented.json - ejecuta el escenario instrumentado",
            file=sys.stderr,
        )
    if not base or not instr:
        print("\nNo hay suficientes datos para comparar.", file=sys.stderr)
        return 1

    print("Consultando metricas de recursos en " + args.prometheus)
    recursos = recolectar_recursos(args.prometheus, args.ventana)

    filas = construir_tabla(base, instr, recursos)

    print("\nOVERHEAD DE OPENTELEMETRY - tabla comparativa\n")
    imprimir_tabla(filas)

    os.makedirs(RESULTS_DIR, exist_ok=True)
    escribir_markdown(filas, base, instr, args.salida)

    # JSON crudo para reutilizarlo en el reporte final.
    with open(
        os.path.join(RESULTS_DIR, "overhead.json"), "w", encoding="utf-8"
    ) as fh:
        json.dump(
            {
                "generado": datetime.now().isoformat(),
                "tabla": filas,
                "k6_baseline": base,
                "k6_instrumented": instr,
                "recursos": recursos,
            },
            fh,
            indent=2,
            ensure_ascii=False,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
