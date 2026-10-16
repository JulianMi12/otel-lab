#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# EXPERIMENTO 1 — Inyección de latencia de red en service-b
#
# HIPÓTESIS
#   En estado estable (p99 ≈ 360 ms, disponibilidad 100 %), cuando se inyectan
#   200 ms de latencia de red en el camino hacia service-b durante 5 minutos,
#   esperamos que la latencia p99 de service-a aumente aproximadamente en esa
#   cantidad pero que la disponibilidad se mantenga en 100 %, porque el timeout
#   de service-a hacia service-b es de 5 s y conserva margen de sobra.
#
# TIPO DE FALLO      network latency
# BLAST RADIUS       únicamente el camino service-a → service-b. PostgreSQL,
#                    el Collector y el stack de observabilidad quedan fuera.
# DURACIÓN           5 minutos (configurable con DURACION)
# ROLLBACK           automático: DELETE del toxic al salir del script, con un
#                    trap que lo ejecuta aunque el script falle o se interrumpa
# SLI DE IMPACTO     latencia p99 (principal) · disponibilidad (control)
# EVIDENCIA          traza en Jaeger con el span call.service-b.inventory
#                    alargado; métrica http_request_duration_seconds
#
# EQUIVALENTE CONCEPTUAL
#   Chaos Mesh → NetworkChaos { action: delay, latency: 200ms, jitter: 10ms }
#
# HERRAMIENTA: Toxiproxy en lugar de tc netem
#   El plan original era `tc qdisc add ... netem delay`, que es lo que Chaos
#   Mesh ejecuta por debajo. No es viable aquí: el kernel de Docker Desktop
#   sobre WSL2 no incluye el módulo sch_netem y /lib/modules está vacío, de
#   modo que tampoco puede cargarse (`Specified qdisc kind is unknown`).
#
#   Toxiproxy produce el mismo efecto observable —latencia real en el
#   transporte, inyectada FUERA de la aplicación— interponiéndose entre
#   service-a y service-b. Ninguna línea de código de la aplicación sabe del
#   experimento, que es la propiedad que importa: un fallo inyectado dentro
#   del código mediría el `time.sleep()` del propio servicio, no una
#   degradación de red.
#
# Uso:  bash chaos/experimentos/e1-latencia-red.sh
# ════════════════════════════════════════════════════════════════════════════

source "$(dirname "${BASH_SOURCE[0]}")/../comun.sh"

LATENCIA_MS="${LATENCIA_MS:-200}"
JITTER_MS="${JITTER_MS:-10}"
DURACION="${DURACION:-300}"
OBJETIVO="service-b"
TOXIPROXY="${TOXIPROXY:-http://localhost:8474}"
TOXIC="latencia-gameday"

# ── Rollback automático ─────────────────────────────────────────────────────
# El trap garantiza que la latencia se retira aunque el script falle o se
# interrumpa con Ctrl+C. Un experimento de caos sin rollback fiable no debe
# ejecutarse nunca.
revertir() {
  echo ""
  ambar "  [ROLLBACK] retirando el toxic de ${OBJETIVO}..."
  local codigo
  codigo=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
    "${TOXIPROXY}/proxies/service-b/toxics/${TOXIC}" 2>/dev/null)
  if [[ "$codigo" == "204" ]]; then
    verde "  [ROLLBACK] latencia retirada"
  else
    echo "  [ROLLBACK] no había toxic activo (nada que revertir)"
  fi
  detener_carga
}
trap revertir EXIT INT TERM

azul "═══════════════════════════════════════════════════════════════"
azul "  EXPERIMENTO 1 — Latencia de red de ${LATENCIA_MS} ms en ${OBJETIVO}"
azul "═══════════════════════════════════════════════════════════════"

# ── FASE 1 — Probe SOT ──────────────────────────────────────────────────────
fase "FASE 1/5 · Verificación del estado estable (probe SOT)"

probe_steady_state 5 || exit 1

if ! curl -fs -m 10 "${TOXIPROXY}/proxies" > /dev/null 2>&1; then
  rojo "  Toxiproxy no responde en ${TOXIPROXY}"
  rojo "    docker compose -f docker-compose.yaml -f docker-compose.chaos.yaml up -d"
  exit 1
fi
verde "  [SOT] Toxiproxy operativo en el camino service-a → service-b"

iniciar_carga 5
echo "  estabilizando durante 45 s antes de medir la línea base..."
sleep 45

P99_BASE=$(sli_p99 2m)
P95_BASE=$(sli_p95 2m)
DISP_BASE=$(sli_disponibilidad 2m)
TPUT_BASE=$(sli_throughput 2m)

echo ""
echo "  Línea base medida:"
echo "    p99            ${P99_BASE} ms"
echo "    p95            ${P95_BASE} ms"
echo "    disponibilidad ${DISP_BASE} %"
echo "    throughput     ${TPUT_BASE} req/s"

# ── FASE 2 — Inyección del fallo ────────────────────────────────────────────
fase "FASE 2/5 · Inyección del fallo con Toxiproxy"

echo "  llamada a la API de Toxiproxy:"
echo "    POST ${TOXIPROXY}/proxies/service-b/toxics"
echo "    { type: latency, latency: ${LATENCIA_MS}ms, jitter: ${JITTER_MS}ms, toxicity: 1.0 }"
echo ""

RESP=$(curl -s -X POST "${TOXIPROXY}/proxies/service-b/toxics" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${TOXIC}\",\"type\":\"latency\",\"stream\":\"downstream\",\"toxicity\":1.0,\"attributes\":{\"latency\":${LATENCIA_MS},\"jitter\":${JITTER_MS}}}" 2>/dev/null)

if ! echo "$RESP" | grep -q '"name"'; then
  rojo "  No se pudo inyectar el toxic: ${RESP}"
  exit 1
fi

verde "  Fallo inyectado: ${LATENCIA_MS} ms (±${JITTER_MS} ms) hacia ${OBJETIVO}"
echo "  toxics activos:"
curl -s "${TOXIPROXY}/proxies/service-b/toxics" | python -c "
import sys, json
for t in json.load(sys.stdin):
    print('    %s | %s | %s' % (t['name'], t['type'], t['attributes']))
" 2>/dev/null

INICIO_CHAOS=$(date +%s)

# ── FASE 3 — Probe DuringChaos ──────────────────────────────────────────────
fase "FASE 3/5 · Detección de la anomalía (probe DuringChaos)"

# El umbral se fija en el doble de la línea base: suficientemente por encima
# del ruido normal para no producir falsos positivos.
UMBRAL=$(python -c "print(round(${P99_BASE:-100} * 2, 1))")
echo "  umbral de detección: p99 > ${UMBRAL} ms"

medir_mttd \
  "histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{source=\"collector\"}[1m]))) * 1000" \
  "$UMBRAL" 120
MTTD=$(cat /tmp/mttd_resultado 2>/dev/null || echo "-1")

# ── FASE 4 — Medición sostenida ─────────────────────────────────────────────
fase "FASE 4/5 · Medición bajo fallo sostenido"

AHORA=$(date +%s)
RESTANTE=$((DURACION - (AHORA - INICIO_CHAOS)))
if (( RESTANTE > 0 )); then
  echo "  manteniendo el fallo ${RESTANTE}s más para estabilizar las métricas..."
  sleep "$RESTANTE"
fi

P99_CHAOS=$(sli_p99 1m)
P95_CHAOS=$(sli_p95 1m)
DISP_CHAOS=$(sli_disponibilidad 1m)
TPUT_CHAOS=$(sli_throughput 1m)

echo ""
echo "  Durante el fallo:"
echo "    p99            ${P99_CHAOS} ms    (base: ${P99_BASE})"
echo "    p95            ${P95_CHAOS} ms    (base: ${P95_BASE})"
echo "    disponibilidad ${DISP_CHAOS} %    (base: ${DISP_BASE})"
echo "    throughput     ${TPUT_CHAOS} req/s (base: ${TPUT_BASE})"

TRAZA=$(curl -s -m 25 "${SERVICE_A}/order/ORD-0001" | python -c "import sys,json;print(json.load(sys.stdin).get('trace_id',''))" 2>/dev/null)
echo ""
echo "  traza de ejemplo bajo fallo: ${TRAZA}"

# ── FASE 5 — Rollback y probe EOT ───────────────────────────────────────────
fase "FASE 5/5 · Rollback y verificación de recuperación (probe EOT)"

CODIGO_RB=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
  "${TOXIPROXY}/proxies/service-b/toxics/${TOXIC}" 2>/dev/null)
[[ "$CODIGO_RB" == "204" ]] \
  && verde "  [ROLLBACK] latencia retirada (HTTP 204)" \
  || ambar "  [ROLLBACK] respuesta inesperada: ${CODIGO_RB}"

probe_recuperacion "${P99_BASE:-100}" 2.0 120
RECUPERACION=$(cat /tmp/recuperacion_resultado 2>/dev/null || echo "-1")

P99_POST=$(sli_p99 1m)
DISP_POST=$(sli_disponibilidad 1m)

detener_carga

# ── Resultado ───────────────────────────────────────────────────────────────
fase "RESULTADO DEL EXPERIMENTO 1"

DELTA=$(python -c "print(round(${P99_CHAOS:-0} - ${P99_BASE:-0}, 1))")

printf "  %-22s %12s %12s %12s\n" "SLI" "base" "con fallo" "post"
printf "  %-22s %12s %12s %12s\n" "----------------------" "------------" "------------" "------------"
printf "  %-22s %12s %12s %12s\n" "Latencia p99 (ms)"  "$P99_BASE"  "$P99_CHAOS"  "$P99_POST"
printf "  %-22s %12s %12s %12s\n" "Latencia p95 (ms)"  "$P95_BASE"  "$P95_CHAOS"  "-"
printf "  %-22s %12s %12s %12s\n" "Disponibilidad (%)" "$DISP_BASE" "$DISP_CHAOS" "$DISP_POST"
printf "  %-22s %12s %12s %12s\n" "Throughput (req/s)" "$TPUT_BASE" "$TPUT_CHAOS" "-"
echo ""
echo "  Incremento de p99:  ${DELTA} ms   (latencia inyectada: ${LATENCIA_MS} ms)"
echo "  MTTD:               ${MTTD} s"
echo "  Recuperación:       ${RECUPERACION} s"

guardar_resultado "e1-latencia-red.json" \
  "experimento=E1 - Latencia de red" \
  "tipo_fallo=network latency" \
  "herramienta=Toxiproxy (latency toxic)" \
  "objetivo=${OBJETIVO}" \
  "latencia_inyectada_ms=${LATENCIA_MS}" \
  "jitter_ms=${JITTER_MS}" \
  "duracion_s=${DURACION}" \
  "p99_base_ms=${P99_BASE}" "p99_chaos_ms=${P99_CHAOS}" "p99_post_ms=${P99_POST}" \
  "p95_base_ms=${P95_BASE}" "p95_chaos_ms=${P95_CHAOS}" \
  "disponibilidad_base=${DISP_BASE}" "disponibilidad_chaos=${DISP_CHAOS}" \
  "disponibilidad_post=${DISP_POST}" \
  "throughput_base=${TPUT_BASE}" "throughput_chaos=${TPUT_CHAOS}" \
  "delta_p99_ms=${DELTA}" "mttd_s=${MTTD}" "recuperacion_s=${RECUPERACION}" \
  "trace_id=${TRAZA}"

echo ""
verde "  Experimento 1 finalizado."
