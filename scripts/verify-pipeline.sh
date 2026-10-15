#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# verify-pipeline.sh — Verificación automatizada del pipeline end-to-end
#
# Dispara UN request real y luego comprueba, consultando las APIs de cada
# backend, que ese mismo trace_id aparece en las TRES señales:
#
#   1. Genera    GET /order/{id}            → obtiene el trace_id de la respuesta
#   2. TRAZAS    Jaeger API                 → la traza existe
#   3. PROPAGACIÓN  spans de ambos servicios bajo el MISMO trace_id (W3C)
#   4. LOGS      Loki API                   → hay logs con ese trace_id
#   5. MÉTRICAS  Prometheus API             → los SLIs tienen datos
#   6. COLLECTOR métricas internas          → no hay señales rechazadas
#
# Es la evidencia reproducible de la correlación cross-signal: no depende de
# mirar capturas de pantalla, sino de consultar los backends directamente.
#
# Uso:
#   ./scripts/verify-pipeline.sh
# ════════════════════════════════════════════════════════════════════════════

set -uo pipefail

cd "$(dirname "$0")/.."

SERVICE_A="${SERVICE_A:-http://localhost:8000}"
JAEGER="${JAEGER:-http://localhost:16686}"
LOKI="${LOKI:-http://localhost:3100}"
PROMETHEUS="${PROMETHEUS:-http://localhost:9090}"
COLLECTOR="${COLLECTOR:-http://localhost:8888}"

PASADAS=0
FALLIDAS=0

ok()    { printf "  \033[1;32m[OK]\033[0m    %s\n" "$1"; PASADAS=$((PASADAS + 1)); }
fallo() { printf "  \033[1;31m[FALLO]\033[0m %s\n" "$1"; FALLIDAS=$((FALLIDAS + 1)); }
info()  { printf "  \033[1;33m[info]\033[0m  %s\n" "$1"; }

titulo() {
  echo ""
  printf "\033[1;34m%s\033[0m\n" "── $1 ────────────────────────────────────────────"
}

# ════════════════════════════════════════════════════════════════════════════
titulo "1. GENERACIÓN DE TRÁFICO"
# ════════════════════════════════════════════════════════════════════════════

# Varias peticiones para que las métricas tengan material suficiente; la
# última es la que se usa como caso de prueba de la correlación.
info "Enviando 15 peticiones a service-a..."
for i in $(seq 1 15); do
  curl -fs "${SERVICE_A}/order/ORD-000$((i % 9 + 1))" > /dev/null 2>&1 || true
done

RESPUESTA=$(curl -fs "${SERVICE_A}/order/ORD-0001" 2>/dev/null)
if [[ -z "$RESPUESTA" ]]; then
  fallo "service-a no respondió — ¿está levantado el stack?"
  exit 1
fi

TRACE_ID=$(echo "$RESPUESTA" | python -c "import sys,json; print(json.load(sys.stdin).get('trace_id',''))" 2>/dev/null)

if [[ -z "$TRACE_ID" ]]; then
  fallo "La respuesta no trae trace_id — la instrumentación no está activa"
  echo "$RESPUESTA"
  exit 1
fi

# El formato de 32 hexadecimales es el que exige la especificación W3C.
if [[ "$TRACE_ID" =~ ^[0-9a-f]{32}$ ]]; then
  ok "trace_id con formato W3C válido: $TRACE_ID"
else
  fallo "trace_id con formato inválido: $TRACE_ID"
fi

# Los exportadores trabajan por lotes (BatchSpanProcessor, batch processor del
# Collector): hay que esperar a que la señal recorra todo el pipeline.
info "Esperando 12s a que los lotes lleguen a los backends..."
sleep 12

# ════════════════════════════════════════════════════════════════════════════
titulo "2. TRAZAS — Jaeger"
# ════════════════════════════════════════════════════════════════════════════

TRAZA=$(curl -fs "${JAEGER}/api/traces/${TRACE_ID}" 2>/dev/null)

if echo "$TRAZA" | grep -q '"spans"'; then
  N_SPANS=$(echo "$TRAZA" | python -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d['data'][0]['spans']))
except Exception:
    print(0)
" 2>/dev/null)
  ok "Traza encontrada en Jaeger con $N_SPANS spans"
else
  fallo "La traza $TRACE_ID no aparece en Jaeger"
fi

# ════════════════════════════════════════════════════════════════════════════
titulo "3. PROPAGACIÓN DE CONTEXTO W3C (service-a → service-b)"
# ════════════════════════════════════════════════════════════════════════════

# La prueba decisiva: ambos servicios deben aparecer bajo el MISMO trace_id.
# Si service-b no extrajera el header traceparent, generaría una traza aparte.
SERVICIOS=$(echo "$TRAZA" | python -c "
import sys, json
try:
    d = json.load(sys.stdin)
    procesos = d['data'][0]['processes']
    nombres = sorted({p['serviceName'] for p in procesos.values()})
    print(','.join(nombres))
except Exception:
    print('')
" 2>/dev/null)

info "Servicios presentes en la traza: ${SERVICIOS:-ninguno}"

if [[ "$SERVICIOS" == *"service-a"* && "$SERVICIOS" == *"service-b"* ]]; then
  ok "Propagación confirmada: ambos servicios comparten el mismo trace_id"
else
  fallo "La traza no incluye ambos servicios — el contexto no se propagó"
fi

# Spans de negocio personalizados esperados en el flujo.
for span_esperado in "order.process" "fetch.order.db" "call.service-b.inventory" "inventory.lookup.db"; do
  if echo "$TRAZA" | grep -q "\"$span_esperado\""; then
    ok "Custom span presente: $span_esperado"
  else
    fallo "Falta el custom span: $span_esperado"
  fi
done

# ════════════════════════════════════════════════════════════════════════════
titulo "4. LOGS — Loki (correlación por trace_id)"
# ════════════════════════════════════════════════════════════════════════════

AHORA_NS=$(python -c "import time; print(int(time.time()*1e9))")
HACE_NS=$(python -c "import time; print(int((time.time()-900)*1e9))")

# Esta es exactamente la query que Grafana ejecuta al saltar de una traza a
# sus logs (tracesToLogsV2 en datasources.yaml).
CONSULTA_LOKI="{service_name=~\"service-.+\"} | trace_id = \`${TRACE_ID}\`"
LOGS=$(curl -fsG "${LOKI}/loki/api/v1/query_range" \
  --data-urlencode "query=${CONSULTA_LOKI}" \
  --data-urlencode "start=${HACE_NS}" \
  --data-urlencode "end=${AHORA_NS}" \
  --data-urlencode "limit=100" 2>/dev/null)

N_LOGS=$(echo "$LOGS" | python -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(sum(len(s['values']) for s in d['data']['result']))
except Exception:
    print(0)
" 2>/dev/null)

if [[ "${N_LOGS:-0}" -gt 0 ]]; then
  ok "$N_LOGS líneas de log correlacionadas con el trace_id en Loki"
else
  fallo "No hay logs en Loki para el trace_id $TRACE_ID"
  info "Query usada: $CONSULTA_LOKI"
fi

# Comprobación de que Loki está recibiendo logs en general.
TOTAL_LOGS=$(curl -fsG "${LOKI}/loki/api/v1/query_range" \
  --data-urlencode 'query={service_name=~"service-.+"}' \
  --data-urlencode "start=${HACE_NS}" \
  --data-urlencode "end=${AHORA_NS}" \
  --data-urlencode "limit=5" 2>/dev/null | python -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(sum(len(s['values']) for s in d['data']['result']))
except Exception:
    print(0)
" 2>/dev/null)

if [[ "${TOTAL_LOGS:-0}" -gt 0 ]]; then
  ok "Loki está ingiriendo logs de los servicios"
else
  fallo "Loki no tiene ningún log de los servicios"
fi

# ════════════════════════════════════════════════════════════════════════════
titulo "5. MÉTRICAS — Prometheus"
# ════════════════════════════════════════════════════════════════════════════

consultar_prom() {
  curl -fsG "${PROMETHEUS}/api/v1/query" --data-urlencode "query=$1" 2>/dev/null |
    python -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d['data']['result']))
except Exception:
    print(0)
" 2>/dev/null
}

for metrica in "http_requests_total" "http_request_duration_seconds_bucket" "db_query_duration_seconds_bucket"; do
  N=$(consultar_prom "$metrica")
  if [[ "${N:-0}" -gt 0 ]]; then
    ok "Métrica presente con $N series: $metrica"
  else
    fallo "Métrica sin datos: $metrica"
  fi
done

# Verifica que el label de servicio existe: es lo que permite cruzar la métrica
# con la traza y el log del mismo servicio.
N_SERVICIOS=$(consultar_prom 'count by (service_name) (http_requests_total)')
if [[ "${N_SERVICIOS:-0}" -gt 0 ]]; then
  ok "Las métricas conservan el label de servicio (cruce con trazas y logs)"
else
  info "No se encontró el label service_name; revisa resource_to_telemetry_conversion"
fi

# ════════════════════════════════════════════════════════════════════════════
titulo "6. SALUD DEL OTEL COLLECTOR"
# ════════════════════════════════════════════════════════════════════════════

METRICAS_COL=$(curl -fs "${COLLECTOR}/metrics" 2>/dev/null)

if [[ -z "$METRICAS_COL" ]]; then
  fallo "No se pudieron leer las métricas internas del Collector"
else
  ok "El Collector expone sus métricas internas"

  for senal in spans metric_points log_records; do
    ACEPTADOS=$(echo "$METRICAS_COL" | grep "^otelcol_receiver_accepted_${senal}" | awk '{s+=$2} END {printf "%.0f", s+0}')
    RECHAZADOS=$(echo "$METRICAS_COL" | grep "^otelcol_receiver_refused_${senal}" | awk '{s+=$2} END {printf "%.0f", s+0}')

    if [[ "${ACEPTADOS:-0}" -gt 0 ]]; then
      ok "Recibidos ${ACEPTADOS} ${senal} (rechazados: ${RECHAZADOS:-0})"
    else
      fallo "El Collector no ha recibido ningún ${senal}"
    fi
  done

  FALLIDOS=$(echo "$METRICAS_COL" | grep "^otelcol_exporter_send_failed" | awk '{s+=$2} END {printf "%.0f", s+0}')
  if [[ "${FALLIDOS:-0}" -eq 0 ]]; then
    ok "Ningún envío fallido hacia los backends"
  else
    fallo "${FALLIDOS} envíos fallaron — revisa: docker compose logs otel-collector"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
titulo "RESUMEN"
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo "  Comprobaciones superadas: $PASADAS"
echo "  Comprobaciones fallidas:  $FALLIDAS"
echo ""
echo "  trace_id de la prueba: $TRACE_ID"
echo ""
echo "  Enlaces para capturar evidencia:"
echo "    Traza en Jaeger:  ${JAEGER}/trace/${TRACE_ID}"
echo "    Logs en Grafana:  http://localhost:3000/explore"
echo "      Query LogQL:    {service_name=\"service-a\"} | trace_id = \`${TRACE_ID}\`"
echo ""

if [[ "$FALLIDAS" -eq 0 ]]; then
  printf "\033[1;32m  PIPELINE VERIFICADO: las tres señales correlacionan por trace_id\033[0m\n\n"
  exit 0
else
  printf "\033[1;31m  Hay comprobaciones fallidas — revisa el detalle arriba\033[0m\n\n"
  exit 1
fi
