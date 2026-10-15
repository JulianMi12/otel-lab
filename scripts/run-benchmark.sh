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

azul()  { printf "\033[1;34m%s\033[0m\n" "$1"; }
verde() { printf "\033[1;32m%s\033[0m\n" "$1"; }
rojo()  { printf "\033[1;31m%s\033[0m\n" "$1"; }

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

# Calentamiento: las primeras peticiones pagan la compilación JIT de Python y
# el llenado del pool de conexiones. Incluirlas sesgaría los percentiles.
echo "Calentando (20 peticiones)..."
for i in $(seq 1 20); do
  curl -fs "http://localhost:8010/order/ORD-0001" > /dev/null 2>&1 || true
done

echo ""
echo "Ejecutando carga: $VUS VUs durante $DURATION"
docker compose --profile load run --rm \
  -e TARGET=http://service-a-baseline:8000 \
  -e SCENARIO=baseline \
  -e VUS="$VUS" \
  -e DURATION="$DURATION" \
  -e RAMP="$RAMP" \
  k6 run /scripts/load.js

verde "Línea base completada."

echo "Apagando los servicios de línea base para liberar CPU..."
docker compose --profile baseline stop service-a-baseline service-b-baseline

echo "Reposo de ${REPOSO}s antes de la siguiente fase..."
sleep "$REPOSO"
fi

# ════════════════════════════════════════════════════════════════════════════
separador "FASE 2 / 3 — INSTRUMENTADO (OTel completo)"
# ════════════════════════════════════════════════════════════════════════════

echo "Calentando (20 peticiones)..."
for i in $(seq 1 20); do
  curl -fs "http://localhost:8000/order/ORD-0001" > /dev/null 2>&1 || true
done

echo ""
echo "Ejecutando carga: $VUS VUs durante $DURATION"
docker compose --profile load run --rm \
  -e TARGET=http://service-a:8000 \
  -e SCENARIO=instrumented \
  -e VUS="$VUS" \
  -e DURATION="$DURATION" \
  -e RAMP="$RAMP" \
  k6 run /scripts/load.js

verde "Escenario instrumentado completado."

# Las métricas de recursos se exportan cada 10s; se espera un ciclo completo
# para que Prometheus haya recogido el pico de la prueba.
echo "Esperando 20s a que Prometheus recoja las últimas muestras..."
sleep 20

# ════════════════════════════════════════════════════════════════════════════
separador "FASE 3 / 3 — ANÁLISIS COMPARATIVO"
# ════════════════════════════════════════════════════════════════════════════

python benchmark/analyze_overhead.py --prometheus http://localhost:9090

separador "BENCHMARK FINALIZADO"
echo "Resultados en:"
echo "  benchmark/results/k6-baseline.json"
echo "  benchmark/results/k6-instrumented.json"
echo "  benchmark/results/overhead.md     ← tabla para el reporte"
echo "  benchmark/results/overhead.json"
echo ""
