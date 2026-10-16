#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# EXPERIMENTO 2 — Agotamiento de CPU en service-b
#
# HIPÓTESIS
#   En estado estable (CPU de service-b ≈ 5 %, p95 ≈ 115 ms), cuando se satura
#   por completo la cuota de CPU del contenedor de service-b durante 3 minutos,
#   esperamos que la latencia p95 supere los 500 ms y que el throughput caiga,
#   pero que NO aparezcan errores 5xx, porque la degradación proviene de
#   contención de CPU y no de un fallo de la aplicación: las peticiones siguen
#   completándose, sólo que más despacio.
#
# TIPO DE FALLO      resource exhaustion (CPU)
# BLAST RADIUS       únicamente el contenedor service-b, limitado además por su
#                    cuota de 1.0 CPU. El resto del stack conserva su cuota.
# DURACIÓN           3 minutos (configurable con DURACION)
# ROLLBACK           automático: `pkill stress-ng` al salir, con trap. El
#                    proceso además se autolimita con --timeout, de modo que
#                    muere solo aunque el script desaparezca.
# SLI DE IMPACTO     latencia p95 y throughput (principales)
#                    tasa de errores 5xx (control: debe seguir en 0)
# EVIDENCIA          panel de CPU por contenedor; métrica
#                    container_cpu_utilization_ratio; histograma de latencia
#
# EQUIVALENTE CONCEPTUAL
#   Chaos Mesh → StressChaos { stressors: { cpu: { workers: 2, load: 100 } } }
#   Chaos Mesh ejecuta stress-ng dentro del pod; aquí se ejecuta dentro del
#   contenedor, que es exactamente el mismo mecanismo.
#
# Uso:  bash chaos/experimentos/e2-cpu-exhaustion.sh
# ════════════════════════════════════════════════════════════════════════════

source "$(dirname "${BASH_SOURCE[0]}")/../comun.sh"

WORKERS="${WORKERS:-4}"
DURACION="${DURACION:-180}"
OBJETIVO="service-b"

# ── Rollback automático ─────────────────────────────────────────────────────
revertir() {
  echo ""
  ambar "  [ROLLBACK] deteniendo stress-ng en ${OBJETIVO}..."
  docker exec -u root "$OBJETIVO" pkill -f stress-ng 2>/dev/null \
    && verde "  [ROLLBACK] stress-ng detenido" \
    || echo "  [ROLLBACK] stress-ng ya no estaba corriendo"
  detener_carga
}
trap revertir EXIT INT TERM

azul "═══════════════════════════════════════════════════════════════"
azul "  EXPERIMENTO 2 — Agotamiento de CPU en ${OBJETIVO}"
azul "═══════════════════════════════════════════════════════════════"

# ── FASE 1 — Probe SOT ──────────────────────────────────────────────────────
fase "FASE 1/5 · Verificación del estado estable (probe SOT)"

probe_steady_state 5 || exit 1

# procps aporta pgrep y pkill, imprescindibles para verificar el arranque
# del estresador y, sobre todo, para poder revertirlo.
instalar_herramientas "$OBJETIVO" "stress-ng procps" || exit 1

iniciar_carga 5
echo "  estabilizando durante 45 s antes de medir la línea base..."
sleep 45

P95_BASE=$(sli_p95 2m)
P99_BASE=$(sli_p99 2m)
DISP_BASE=$(sli_disponibilidad 2m)
TPUT_BASE=$(sli_throughput 2m)
CPU_BASE=$(cpu_contenedor "$OBJETIVO")

echo ""
echo "  Línea base medida:"
echo "    p95            ${P95_BASE} ms"
echo "    p99            ${P99_BASE} ms"
echo "    disponibilidad ${DISP_BASE} %"
echo "    throughput     ${TPUT_BASE} req/s"
echo "    CPU ${OBJETIVO}  ${CPU_BASE} %"

# ── FASE 2 — Inyección del fallo ────────────────────────────────────────────
fase "FASE 2/5 · Inyección del fallo con stress-ng"

echo "  comando:"
echo "    stress-ng --cpu ${WORKERS} --cpu-load 100 --timeout $((DURACION + 60))s"
echo ""
echo "  Nota: --timeout actúa como segundo mecanismo de rollback. Aunque el"
echo "  script muera, stress-ng se detiene solo y el sistema se recupera."
echo ""

docker exec -u root -d "$OBJETIVO" \
  stress-ng --cpu "$WORKERS" --cpu-load 100 --timeout "$((DURACION + 60))s"

sleep 5
PROCESOS=$(docker exec -u root "$OBJETIVO" sh -c "pgrep -c -f stress-ng 2>/dev/null || echo 0" 2>/dev/null | tr -d '')
if [[ "${PROCESOS:-0}" -gt 0 ]]; then
  verde "  Fallo inyectado: ${PROCESOS} procesos stress-ng consumiendo CPU al 100 %"
else
  rojo "  stress-ng no arrancó (procesos detectados: ${PROCESOS:-0})"
  exit 1
fi

INICIO_CHAOS=$(date +%s)

# ── FASE 3 — Probe DuringChaos ──────────────────────────────────────────────
fase "FASE 3/5 · Detección de la anomalía (probe DuringChaos)"

# Aquí el SLI que delata el fallo es la CPU del contenedor, más directo que la
# latencia: la saturación es la causa y la latencia, la consecuencia.
echo "  umbral de detección: CPU de ${OBJETIVO} > 50 %"

medir_mttd \
  "max(container_cpu_utilization_ratio{container_name=\"${OBJETIVO}\"})" \
  50 120
MTTD=$(cat /tmp/mttd_resultado 2>/dev/null || echo "-1")

# ── FASE 4 — Medición sostenida ─────────────────────────────────────────────
fase "FASE 4/5 · Medición bajo fallo sostenido"

AHORA=$(date +%s)
RESTANTE=$((DURACION - (AHORA - INICIO_CHAOS)))
if (( RESTANTE > 0 )); then
  echo "  manteniendo el fallo ${RESTANTE}s más para estabilizar las métricas..."
  sleep "$RESTANTE"
fi

P95_CHAOS=$(sli_p95 1m)
P99_CHAOS=$(sli_p99 1m)
DISP_CHAOS=$(sli_disponibilidad 1m)
TPUT_CHAOS=$(sli_throughput 1m)
CPU_CHAOS=$(cpu_contenedor "$OBJETIVO")

echo ""
echo "  Durante el fallo:"
echo "    p95            ${P95_CHAOS} ms    (base: ${P95_BASE})"
echo "    p99            ${P99_CHAOS} ms    (base: ${P99_BASE})"
echo "    disponibilidad ${DISP_CHAOS} %    (base: ${DISP_BASE})"
echo "    throughput     ${TPUT_CHAOS} req/s (base: ${TPUT_BASE})"
echo "    CPU ${OBJETIVO}  ${CPU_CHAOS} %    (base: ${CPU_BASE})"

TRAZA=$(curl -s -m 25 "${SERVICE_A}/order/ORD-0001" | python -c "import sys,json;print(json.load(sys.stdin).get('trace_id',''))" 2>/dev/null)
echo ""
echo "  traza de ejemplo bajo fallo: ${TRAZA}"

# ── FASE 5 — Rollback y probe EOT ───────────────────────────────────────────
fase "FASE 5/5 · Rollback y verificación de recuperación (probe EOT)"

docker exec -u root "$OBJETIVO" pkill -f stress-ng 2>/dev/null \
  && verde "  [ROLLBACK] stress-ng detenido" \
  || ambar "  [ROLLBACK] stress-ng ya había terminado por su propio timeout"

probe_recuperacion "${P99_BASE:-100}" 2.0 120
RECUPERACION=$(cat /tmp/recuperacion_resultado 2>/dev/null || echo "-1")

sleep 15
P95_POST=$(sli_p95 1m)
DISP_POST=$(sli_disponibilidad 1m)
CPU_POST=$(cpu_contenedor "$OBJETIVO")

detener_carga

# ── Resultado ───────────────────────────────────────────────────────────────
fase "RESULTADO DEL EXPERIMENTO 2"

printf "  %-22s %12s %12s %12s\n" "SLI" "base" "con fallo" "post"
printf "  %-22s %12s %12s %12s\n" "----------------------" "------------" "------------" "------------"
printf "  %-22s %12s %12s %12s\n" "Latencia p95 (ms)"  "$P95_BASE"  "$P95_CHAOS"  "$P95_POST"
printf "  %-22s %12s %12s %12s\n" "Latencia p99 (ms)"  "$P99_BASE"  "$P99_CHAOS"  "-"
printf "  %-22s %12s %12s %12s\n" "Disponibilidad (%)" "$DISP_BASE" "$DISP_CHAOS" "$DISP_POST"
printf "  %-22s %12s %12s %12s\n" "Throughput (req/s)" "$TPUT_BASE" "$TPUT_CHAOS" "-"
printf "  %-22s %12s %12s %12s\n" "CPU service-b (%)"  "$CPU_BASE"  "$CPU_CHAOS"  "$CPU_POST"
echo ""
echo "  MTTD:               ${MTTD} s"
echo "  Recuperación:       ${RECUPERACION} s"

guardar_resultado "e2-cpu-exhaustion.json" \
  "experimento=E2 - Agotamiento de CPU" \
  "tipo_fallo=resource exhaustion (CPU)" \
  "herramienta=stress-ng" \
  "objetivo=${OBJETIVO}" \
  "workers=${WORKERS}" \
  "duracion_s=${DURACION}" \
  "p95_base_ms=${P95_BASE}" "p95_chaos_ms=${P95_CHAOS}" "p95_post_ms=${P95_POST}" \
  "p99_base_ms=${P99_BASE}" "p99_chaos_ms=${P99_CHAOS}" \
  "disponibilidad_base=${DISP_BASE}" "disponibilidad_chaos=${DISP_CHAOS}" \
  "disponibilidad_post=${DISP_POST}" \
  "throughput_base=${TPUT_BASE}" "throughput_chaos=${TPUT_CHAOS}" \
  "cpu_base=${CPU_BASE}" "cpu_chaos=${CPU_CHAOS}" "cpu_post=${CPU_POST}" \
  "mttd_s=${MTTD}" "recuperacion_s=${RECUPERACION}" \
  "trace_id=${TRAZA}"

echo ""
verde "  Experimento 2 finalizado."
