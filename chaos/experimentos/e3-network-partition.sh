#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# EXPERIMENTO 3 — Partición de red: service-b inalcanzable
#
# HIPÓTESIS
#   En estado estable (disponibilidad 100 %), cuando service-b deja de ser
#   alcanzable por completo durante 2 minutos, esperamos que service-a siga
#   respondiendo HTTP 200 con `inventory.available = -1` —degradación
#   elegante— en lugar de propagar un 5xx al cliente, y que el contador
#   `service_b_calls_total{result="unavailable"}` registre cada fallo.
#
#   SOSPECHA PREVIA: el timeout de service-a hacia service-b es de 5 s. Si cada
#   petición espera ese tiempo completo antes de degradar, bajo carga
#   concurrente las peticiones se acumularán y el propio service-a podría
#   saturarse. La hipótesis es que la degradación es elegante; el experimento
#   existe precisamente para comprobar si ese timeout la hace inviable.
#
# TIPO DE FALLO      network partition
# BLAST RADIUS       la dependencia service-a → service-b. PostgreSQL y el
#                    stack de observabilidad siguen accesibles, de modo que la
#                    telemetría del incidente se sigue recogiendo.
# DURACIÓN           2 minutos (configurable con DURACION)
# ROLLBACK           automático: reconexión del contenedor a la red al salir,
#                    con trap. Es el rollback más crítico de los tres: dejar
#                    un servicio desconectado rompe el entorno por completo.
# SLI DE IMPACTO     disponibilidad de service-a (principal)
#                    latencia p99 y tasa de fallback (secundarios)
# EVIDENCIA          logs con "service-b inalcanzable"; contador
#                    service_b_calls_total{result="unavailable"}; trazas con
#                    el span call.service-b.inventory en estado ERROR
#
# EQUIVALENTE CONCEPTUAL
#   Chaos Mesh → NetworkChaos { action: partition, direction: both }
#   LitmusChaos → pod-network-partition
#   Aquí se desconecta el contenedor de la red Docker, que produce el mismo
#   efecto: el destino deja de ser resoluble y alcanzable.
#
# Uso:  bash chaos/experimentos/e3-network-partition.sh
# ════════════════════════════════════════════════════════════════════════════

source "$(dirname "${BASH_SOURCE[0]}")/../comun.sh"

DURACION="${DURACION:-120}"
OBJETIVO="service-b"
RED="otel-lab_otel-net"
DESCONECTADO=0

# ── Rollback automático ─────────────────────────────────────────────────────
# El más importante de los tres: si el script muere con el servicio
# desconectado, el entorno queda roto hasta que alguien lo note.
revertir() {
  echo ""
  if [[ "$DESCONECTADO" == "1" ]]; then
    ambar "  [ROLLBACK] reconectando ${OBJETIVO} a la red ${RED}..."
    docker network connect "$RED" "$OBJETIVO" 2>/dev/null \
      && verde "  [ROLLBACK] ${OBJETIVO} reconectado" \
      || rojo "  [ROLLBACK] FALLÓ la reconexión — revisar manualmente:
        docker network connect ${RED} ${OBJETIVO}"
    DESCONECTADO=0
  fi
  detener_carga
}
trap revertir EXIT INT TERM

azul "═══════════════════════════════════════════════════════════════"
azul "  EXPERIMENTO 3 — Partición de red: ${OBJETIVO} inalcanzable"
azul "═══════════════════════════════════════════════════════════════"

# ── FASE 1 — Probe SOT ──────────────────────────────────────────────────────
fase "FASE 1/5 · Verificación del estado estable (probe SOT)"

probe_steady_state 5 || exit 1

iniciar_carga 5
echo "  estabilizando durante 45 s antes de medir la línea base..."
sleep 45

P99_BASE=$(sli_p99 2m)
DISP_BASE=$(sli_disponibilidad 2m)
TPUT_BASE=$(sli_throughput 2m)
FALLBACK_BASE=$(fallbacks)

echo ""
echo "  Línea base medida:"
echo "    p99            ${P99_BASE} ms"
echo "    disponibilidad ${DISP_BASE} %"
echo "    throughput     ${TPUT_BASE} req/s"
echo "    fallbacks      ${FALLBACK_BASE:-0}"

# ── FASE 2 — Inyección del fallo ────────────────────────────────────────────
fase "FASE 2/5 · Inyección del fallo: desconexión de red"

echo "  comando:"
echo "    docker network disconnect ${RED} ${OBJETIVO}"
echo ""

if docker network disconnect "$RED" "$OBJETIVO" 2>/dev/null; then
  DESCONECTADO=1
  verde "  Fallo inyectado: ${OBJETIVO} desconectado de la red"
else
  rojo "  No se pudo desconectar ${OBJETIVO} de ${RED}"
  exit 1
fi

INICIO_CHAOS=$(date +%s)

# Comprobación directa de cómo responde service-a con su dependencia caída.
echo ""
echo "  respuesta de service-a con la dependencia caída:"
RESP_FALLO=$(curl -s -m 30 -w "\n  tiempo: %{time_total}s | HTTP %{http_code}" \
  "${SERVICE_A}/order/ORD-0001" 2>/dev/null)
echo "$RESP_FALLO" | python -c "
import sys
texto = sys.stdin.read()
lineas = texto.strip().split('\n')
cuerpo = lineas[0] if lineas else ''
try:
    import json
    d = json.loads(cuerpo)
    inv = d.get('inventory', {})
    print('    inventory.available : %s' % inv.get('available'))
    print('    inventory.error     : %s' % inv.get('error'))
    print('    fulfillable         : %s' % d.get('fulfillable'))
except Exception:
    print('    cuerpo no parseable: %s' % cuerpo[:140])
for l in lineas[1:]:
    print(l)
" 2>/dev/null

# ── FASE 3 — Probe DuringChaos ──────────────────────────────────────────────
fase "FASE 3/5 · Detección de la anomalía (probe DuringChaos)"

echo "  umbral de detección: llamadas con result=unavailable > ${FALLBACK_BASE:-0}"

medir_mttd \
  "sum(service_b_calls_total{source=\"collector\",result=\"unavailable\"}) or vector(0)" \
  "${FALLBACK_BASE:-0}" 120
MTTD=$(cat /tmp/mttd_resultado 2>/dev/null || echo "-1")

# ── FASE 4 — Medición sostenida ─────────────────────────────────────────────
fase "FASE 4/5 · Medición bajo fallo sostenido"

AHORA=$(date +%s)
RESTANTE=$((DURACION - (AHORA - INICIO_CHAOS)))
if (( RESTANTE > 0 )); then
  echo "  manteniendo el fallo ${RESTANTE}s más..."
  sleep "$RESTANTE"
fi

P99_CHAOS=$(sli_p99 1m)
DISP_CHAOS=$(sli_disponibilidad 1m)
TPUT_CHAOS=$(sli_throughput 1m)
FALLBACK_CHAOS=$(fallbacks)

echo ""
echo "  Durante el fallo:"
echo "    p99            ${P99_CHAOS} ms    (base: ${P99_BASE})"
echo "    disponibilidad ${DISP_CHAOS} %    (base: ${DISP_BASE})"
echo "    throughput     ${TPUT_CHAOS} req/s (base: ${TPUT_BASE})"
echo "    fallbacks      ${FALLBACK_CHAOS:-0}  (base: ${FALLBACK_BASE:-0})"

echo ""
echo "  logs de degradación en service-a:"
docker logs service-a --since 3m 2>&1 \
  | grep -i "inalcanzable\|unavailable" | tail -3 | sed 's/^/    /' \
  || echo "    (sin coincidencias)"

# ── FASE 5 — Rollback y probe EOT ───────────────────────────────────────────
fase "FASE 5/5 · Rollback y verificación de recuperación (probe EOT)"

docker network connect "$RED" "$OBJETIVO" 2>/dev/null \
  && { DESCONECTADO=0; verde "  [ROLLBACK] ${OBJETIVO} reconectado a la red"; } \
  || rojo "  [ROLLBACK] fallo al reconectar"

echo "  esperando a que service-b vuelva a responder..."
for i in $(seq 1 30); do
  if curl -fs -m 5 "http://localhost:8001/health" > /dev/null 2>&1; then
    verde "  service-b responde de nuevo (${i}s)"
    break
  fi
  sleep 1
done

probe_recuperacion "${P99_BASE:-100}" 2.0 150
RECUPERACION=$(cat /tmp/recuperacion_resultado 2>/dev/null || echo "-1")

sleep 10
P99_POST=$(sli_p99 1m)
DISP_POST=$(sli_disponibilidad 1m)

detener_carga

# ── Resultado ───────────────────────────────────────────────────────────────
fase "RESULTADO DEL EXPERIMENTO 3"

printf "  %-24s %12s %12s %12s\n" "SLI" "base" "con fallo" "post"
printf "  %-24s %12s %12s %12s\n" "------------------------" "------------" "------------" "------------"
printf "  %-24s %12s %12s %12s\n" "Latencia p99 (ms)"    "$P99_BASE"  "$P99_CHAOS"  "$P99_POST"
printf "  %-24s %12s %12s %12s\n" "Disponibilidad (%)"   "$DISP_BASE" "$DISP_CHAOS" "$DISP_POST"
printf "  %-24s %12s %12s %12s\n" "Throughput (req/s)"   "$TPUT_BASE" "$TPUT_CHAOS" "-"
printf "  %-24s %12s %12s %12s\n" "Fallbacks (contador)" "${FALLBACK_BASE:-0}" "${FALLBACK_CHAOS:-0}" "-"
echo ""
echo "  MTTD:               ${MTTD} s"
echo "  Recuperación:       ${RECUPERACION} s"

guardar_resultado "e3-network-partition.json" \
  "experimento=E3 - Particion de red" \
  "tipo_fallo=network partition" \
  "herramienta=docker network disconnect" \
  "objetivo=${OBJETIVO}" \
  "duracion_s=${DURACION}" \
  "p99_base_ms=${P99_BASE}" "p99_chaos_ms=${P99_CHAOS}" "p99_post_ms=${P99_POST}" \
  "disponibilidad_base=${DISP_BASE}" "disponibilidad_chaos=${DISP_CHAOS}" \
  "disponibilidad_post=${DISP_POST}" \
  "throughput_base=${TPUT_BASE}" "throughput_chaos=${TPUT_CHAOS}" \
  "fallbacks_base=${FALLBACK_BASE:-0}" "fallbacks_chaos=${FALLBACK_CHAOS:-0}" \
  "mttd_s=${MTTD}" "recuperacion_s=${RECUPERACION}"

echo ""
verde "  Experimento 3 finalizado."
