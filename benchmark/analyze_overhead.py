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

def consultar_rango(base_url, query, inicio, fin, paso=10, timeout=30):
    """
    Ejecuta una query sobre un RANGO temporal concreto y devuelve las series
    con todos sus puntos.

    Es la consulta correcta para este analisis: los dos escenarios se ejecutan
    uno despues de otro, por lo que cada uno debe evaluarse sobre su propia
    ventana de actividad. Una query instantanea con una ventana fija al final
    compararia el periodo activo de un escenario con el periodo inactivo del
    otro, que fue exactamente el error que producia un overhead de CPU negativo.
    """
    url = base_url.rstrip("/") + "/api/v1/query_range?" + urllib.parse.urlencode(
        {"query": query, "start": inicio, "end": fin, "step": paso}
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


def estadisticas_en_ventana(base_url, promql, contenedores, ventana):
    """
    Devuelve {contenedor: {"avg": x, "max": y}} dentro de la ventana indicada.

    Los puntos se agregan en Python en lugar de con avg_over_time para poder
    informar cuantas muestras respaldan cada valor: con una ventana corta y un
    intervalo de scraping de 10 s, un promedio calculado sobre dos muestras no
    merece la misma confianza que uno calculado sobre treinta.
    """
    salida = {}

    for nombre in contenedores:
        query = promql.format(contenedor=nombre)
        series = consultar_rango(
            base_url, query, ventana["inicio"], ventana["fin"]
        )

        puntos = []
        for s in series:
            for _, valor in s.get("values", []):
                try:
                    v = float(valor)
                except (TypeError, ValueError):
                    continue
                # NaN no es comparable y contaminaria el promedio.
                if v == v:
                    puntos.append(v)

        if puntos:
            salida[nombre] = {
                "avg": sum(puntos) / len(puntos),
                "max": max(puntos),
                "muestras": len(puntos),
            }
        else:
            salida[nombre] = {"avg": None, "max": None, "muestras": 0}

    return salida


def recolectar_recursos_por_ventana(base_url, ventanas):
    """
    CPU y memoria de cada escenario dentro de SU ventana de carga.

    El Collector se mide aparte: en el escenario instrumentado parte del costo
    de la telemetria se desplaza de los servicios al propio Collector, y
    sumarlo a los servicios o ignorarlo por completo daria dos lecturas
    distintas del mismo fenomeno. Se reporta por separado para que el costo
    total sea explicito.
    """
    recursos = {}

    for escenario, contenedores in CONTENEDORES.items():
        ventana = ventanas.get(escenario)
        if not ventana:
            print("  [aviso] sin ventana registrada para " + escenario,
                  file=sys.stderr)
            recursos[escenario] = {"cpu": {}, "memoria": {}, "collector": {}}
            continue

        duracion = ventana["fin"] - ventana["inicio"]
        print("  " + escenario + ": ventana de " + str(duracion) + " s")

        cpu = estadisticas_en_ventana(
            base_url,
            'max(container_cpu_utilization_ratio'
            '{{container_name="{contenedor}"}}) by (container_name)',
            contenedores,
            ventana,
        )
        memoria = estadisticas_en_ventana(
            base_url,
            'max(container_memory_usage_total_bytes'
            '{{container_name="{contenedor}"}}) by (container_name)',
            contenedores,
            ventana,
        )
        # El Collector solo trabaja en el escenario instrumentado; en la linea
        # base esta ocioso. Medirlo en ambos hace visible esa diferencia.
        collector = estadisticas_en_ventana(
            base_url,
            'max(container_cpu_utilization_ratio'
            '{{container_name="{contenedor}"}}) by (container_name)',
            ["otel-collector"],
            ventana,
        )

        recursos[escenario] = {
            "cpu": cpu,
            "memoria": memoria,
            "collector": collector,
        }

    return recursos


# -----------------------------------------------------------------------------
# Lectura de los resultados de k6
# -----------------------------------------------------------------------------
def cargar_resultado_k6(escenario):
    return cargar_json("k6-" + escenario + ".json")


def cargar_json(nombre_archivo):
    ruta = os.path.join(RESULTS_DIR, nombre_archivo)
    if not os.path.exists(ruta):
        return None
    try:
        with open(ruta, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as exc:
        print("  [aviso] no se pudo leer " + nombre_archivo + ": " + str(exc),
              file=sys.stderr)
        return None


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

    # ── Recursos, medidos cada uno en SU ventana de carga ────────────────────
    def agregar(escenario, grupo, estadistico):
        """Suma el estadistico de los dos servicios del escenario."""
        datos = recursos.get(escenario, {}).get(grupo, {})
        valores = [
            v[estadistico]
            for v in datos.values()
            if isinstance(v, dict) and v.get(estadistico) is not None
        ]
        return sum(valores) if valores else None

    # docker_stats ya reporta la utilizacion en porcentaje: no se reescala.
    for etiqueta, estadistico in [
        ("CPU media de los servicios", "avg"),
        ("CPU pico de los servicios", "max"),
    ]:
        b = agregar("baseline", "cpu", estadistico)
        i = agregar("instrumented", "cpu", estadistico)
        filas.append(
            {
                "metrica": etiqueta,
                "unidad": "%",
                "base": fmt(b, " %"),
                "instrumentado": fmt(i, " %"),
                "delta_abs": fmt(i - b, " pp")
                if (b is not None and i is not None)
                else "n/d",
                "delta_pct": fmt_delta(delta_pct(b, i)),
            }
        )

    # CPU del Collector: en la linea base esta ocioso, asi que su consumo
    # durante el escenario instrumentado es costo atribuible a la telemetria.
    b_col = agregar("baseline", "collector", "avg")
    i_col = agregar("instrumented", "collector", "avg")
    filas.append(
        {
            "metrica": "CPU del OTel Collector",
            "unidad": "%",
            "base": fmt(b_col, " %"),
            "instrumentado": fmt(i_col, " %"),
            "delta_abs": fmt(i_col - b_col, " pp")
            if (b_col is not None and i_col is not None)
            else "n/d",
            "delta_pct": fmt_delta(delta_pct(b_col, i_col)),
        }
    )

    # ── Memoria ──────────────────────────────────────────────────────────────
    b_mem = agregar("baseline", "memoria", "max")
    i_mem = agregar("instrumented", "memoria", "max")
    b_mb = b_mem / (1024 * 1024) if b_mem else None
    i_mb = i_mem / (1024 * 1024) if i_mem else None
    filas.append(
        {
            "metrica": "Memoria pico de los servicios",
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

    ventanas = cargar_json("ventanas.json")
    if not ventanas:
        print(
            "\n  [error] falta benchmark/results/ventanas.json.\n"
            "  Lo genera run-benchmark.sh y contiene la ventana temporal de cada\n"
            "  escenario. Sin el, las metricas de CPU y memoria no se pueden\n"
            "  atribuir a la fase correcta.",
            file=sys.stderr,
        )
        return 1

    print("Consultando metricas de recursos en " + args.prometheus)
    recursos = recolectar_recursos_por_ventana(args.prometheus, ventanas)

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
