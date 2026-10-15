#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# run-benchmark.sh — Benchmark comparativo de overhead de OpenTelemetry
#
# Ejecuta la MISMA carga contra dos despliegues idénticos salvo por la
# instrumentación, y produce la tabla comparativa del reporte técnico.
#
#   Fase 1: línea base    → service-a-baseline (OTEL_ENABLED=false)
#   Fase 2: instrumentado → service-a          (OTEL_ENABLED=true)
#   Fase 3: análisis      → analyze_overhead.py cruza k6 + Prometheus
#
# Uso:
#   ./scripts/run-benchmark.sh                 # 75 VUs, 5 minutos (por defecto)
#   VUS=100 DURATION=5m ./scripts/run-benchmark.sh
#   ./scripts/run-benchmark.sh --solo-instrumentado
# ════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Git Bash (MSYS) reescribe los argumentos que parecen rutas absolutas de Unix:
# "/scripts/load.js" se convierte en "C:/Program Files/Git/scripts/load.js"
# antes de llegar al contenedor, y k6 no encuentra el script. Esta variable
# desactiva esa conversión. En Linux y macOS no tiene ningún efecto.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

cd "$(dirname "$0")/.."

# ── Parámetros ──────────────────────────────────────────────────────────────
VUS="${VUS:-75}"
DURATION="${DURATION:-5m}"
RAMP="${RAMP:-30s}"
# Reposo entre fases: deja que los histogramas de Prometheus y los buffers del
# Collector se vacíen, para que la medición de una fase no contamine la otra.
REPOSO="${REPOSO:-45}"

SOLO_INSTRUMENTADO=false
if [[ "${1:-}" == "--solo-instrumentado" ]]; then
  SOLO_INSTRUMENTADO=true
fi

azul()  { printf '\033[1;34m%s\033[0m\n' "$1"; }
verde() { printf '\033[1;32m%s\033[0m\n' "$1"; }
rojo()  { printf '\033[1;31m%s\033[0m\n' "$1"; }
aviso() { printf '\033[1;33m%s\033[0m\n' "$1"; }

separador() {
  echo ""
  azul "════════════════════════════════════════════════════════════════════"
  azul "  $1"
  azul "════════════════════════════════════════════════════════════════════"
}

esperar_salud() {
  local url="$1"
  local nombre="$2"
  local intentos=60

  echo -n "Esperando a que $nombre esté saludable"
  for ((i = 1; i <= intentos; i++)); do
    if curl -fs "$url" > /dev/null 2>&1; then
      echo " listo."
      return 0
    fi
    echo -n "."
    sleep 2
  done

  echo ""
  rojo "$nombre no respondió tras $((intentos * 2)) segundos"
  return 1
}

calentar() {
  # Las primeras peticiones pagan el arranque del intérprete y el llenado del
  # pool de conexiones. Incluirlas sesgaría los percentiles de la medición.
  local url="$1"
  echo "Calentando (20 peticiones)..."
  for _ in $(seq 1 20); do
    curl -fs "${url}/order/ORD-0001" > /dev/null 2>&1 || true
  done
}

# k6 devuelve 99 cuando se cruza algún umbral. Los datos de la corrida siguen
# siendo válidos: el umbral es un SLO de referencia, no una condición de éxito
# del benchmark. Sin este envoltorio, `set -e` abortaría el script tras la
# primera fase y la comparación nunca llegaría a ejecutarse.
escribir_ventana() {
  # Registra la ventana temporal EXACTA en la que cada escenario estuvo bajo
  # carga. Es imprescindible para el analisis: las dos fases se ejecutan una
  # despues de otra, asi que una ventana fija al final compararia el periodo
  # activo de una con el periodo inactivo de la otra.
  #
  # Se descarta la rampa de subida: durante esos segundos todavia no hay la
  # concurrencia objetivo y el promedio de CPU saldria artificialmente bajo.
  local escenario="$1" inicio="$2" fin="$3"
  python - "$escenario" "$inicio" "$fin" "$RAMP" <<'PY'
import json, os, re, sys

escenario, inicio, fin, rampa = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]

# "30s" -> 30 ; "2m" -> 120
m = re.match(r"^(\d+)([smh]?)$", rampa.strip())
segundos = int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[m.group(2)] if m else 30

ruta = os.path.join("benchmark", "results", "ventanas.json")
datos = {}
if os.path.exists(ruta):
    try:
        datos = json.load(open(ruta, encoding="utf-8"))
    except Exception:
        datos = {}

# +10 s extra de margen: el calentamiento y el arranque de k6 tambien diluyen.
datos[escenario] = {"inicio": inicio + segundos + 10, "fin": fin}

with open(ruta, "w", encoding="utf-8") as fh:
    json.dump(datos, fh, indent=2)

print("  ventana de medicion: %d s de meseta" % (fin - (inicio + segundos + 10)))
PY
}

ejecutar_k6() {
  local escenario="$1"
  local objetivo="$2"
  local codigo=0
  local inicio fin

  echo ""
  echo "Ejecutando carga: $VUS VUs durante $DURATION"

  inicio=$(date -u +%s)
  set +e
  docker compose --profile load run --rm \
    -e TARGET="$objetivo" \
    -e SCENARIO="$escenario" \
    -e VUS="$VUS" \
    -e DURATION="$DURATION" \
    -e RAMP="$RAMP" \
    k6 run /scripts/load.js
  codigo=$?
  set -e
  fin=$(date -u +%s)

  escribir_ventana "$escenario" "$inicio" "$fin"

  if [[ $codigo -eq 99 ]]; then
    echo ""
    aviso "  Aviso: se cruzó algún umbral de k6 (exit 99)."
    echo "  Los resultados son válidos; el umbral es un SLO de referencia."
    return 0
  fi

  if [[ $codigo -ne 0 ]]; then
    rojo "k6 falló con código $codigo"
    return "$codigo"
  fi

  return 0
}

mkdir -p benchmark/results

# ════════════════════════════════════════════════════════════════════════════
separador "VERIFICACIÓN PREVIA"
# ════════════════════════════════════════════════════════════════════════════

if ! docker compose ps --services --filter "status=running" | grep -q service-a; then
  rojo "El stack no está levantado. Ejecuta primero: docker compose up -d --build"
  exit 1
fi

esperar_salud "http://localhost:8000/health" "service-a (instrumentado)"
esperar_salud "http://localhost:9090/-/healthy" "Prometheus"

verde "Stack listo."

# ════════════════════════════════════════════════════════════════════════════
if [[ "$SOLO_INSTRUMENTADO" == false ]]; then
separador "FASE 1 / 3 — LÍNEA BASE (sin instrumentación OTel)"
# ════════════════════════════════════════════════════════════════════════════

echo "Levantando los servicios de línea base..."
docker compose --profile baseline up -d service-a-baseline service-b-baseline

esperar_salud "http://localhost:8010/health" "service-a-baseline"
esperar_salud "http://localhost:8011/health" "service-b-baseline"

calentar "http://localhost:8010"
ejecutar_k6 "baseline" "http://service-a-baseline:8000"

verde "Línea base completada."

# Se apagan para que no compitan por CPU durante la segunda fase.
echo "Apagando los servicios de línea base..."
docker compose --profile baseline stop service-a-baseline service-b-baseline

echo "Reposo de ${REPOSO}s antes de la siguiente fase..."
sleep "$REPOSO"
fi

# ════════════════════════════════════════════════════════════════════════════
separador "FASE 2 / 3 — INSTRUMENTADO (OTel completo)"
# ════════════════════════════════════════════════════════════════════════════

calentar "http://localhost:8000"
ejecutar_k6 "instrumented" "http://service-a:8000"

verde "Escenario instrumentado completado."

# Las métricas de recursos se exportan cada 10 s; se espera un ciclo completo
# para que Prometheus haya recogido el pico de la prueba.
echo "Esperando 20s a que Prometheus recoja las últimas muestras..."
sleep 20

# ════════════════════════════════════════════════════════════════════════════
separador "FASE 3 / 3 — ANÁLISIS COMPARATIVO"
# ════════════════════════════════════════════════════════════════════════════

python benchmark/analyze_overhead.py --prometheus http://localhost:9090

# ── Archivado por régimen de carga ──────────────────────────────────────────
# Con ETIQUETA definida, los resultados se mueven a su propia subcarpeta. Es lo
# que permite conservar varias corridas (carga moderada y saturación) y que el
# generador del reporte las presente por separado en vez de pisarse entre sí.
#
#   ETIQUETA=moderada-25vus VUS=25 bash scripts/run-benchmark.sh
if [[ -n "${ETIQUETA:-}" ]]; then
  DESTINO="benchmark/results/${ETIQUETA}"
  mkdir -p "$DESTINO"
  for f in k6-baseline.json k6-instrumented.json overhead.json overhead.md ventanas.json; do
    [[ -f "benchmark/results/$f" ]] && mv "benchmark/results/$f" "$DESTINO/"
  done
  verde "Resultados archivados en $DESTINO/"
fi

separador "BENCHMARK FINALIZADO"
echo "Resultados en:"
if [[ -n "${ETIQUETA:-}" ]]; then
  echo "  benchmark/results/${ETIQUETA}/"
else
  echo "  benchmark/results/"
fi
echo "    k6-baseline.json      métricas de cliente, línea base"
echo "    k6-instrumented.json  métricas de cliente, instrumentado"
echo "    overhead.md           tabla comparativa"
echo "    overhead.json         datos crudos para el reporte"
echo "    ventanas.json         intervalo de carga de cada escenario"
echo ""
