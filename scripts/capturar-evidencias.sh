#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# capturar-evidencias.sh — Capturas automatizadas para el entregable
#
# Genera un request real, obtiene su trace_id y captura con Chrome headless:
#
#   1. Jaeger  — la traza completa con spans de ambos servicios
#   2. Jaeger  — búsqueda de trazas del servicio
#   3. Grafana — dashboard con los SLIs y el overhead de recursos
#   4. Grafana — Explore de Loki filtrado por ese trace_id
#   5. Prometheus — targets activos
#
# Automatizarlo evita que las capturas se desincronicen del estado real del
# sistema: cada ejecución produce evidencia del pipeline tal y como está ahora.
#
# Uso:
#   bash scripts/capturar-evidencias.sh
# ════════════════════════════════════════════════════════════════════════════

set -uo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

cd "$(dirname "$0")/.."

DESTINO="docs/evidencias"
mkdir -p "$DESTINO"

# ── Localizar el navegador ──────────────────────────────────────────────────
CANDIDATOS=(
  "/c/Program Files/Google/Chrome/Application/chrome.exe"
  "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"
  "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  "$(command -v google-chrome 2>/dev/null || true)"
)

NAVEGADOR=""
for c in "${CANDIDATOS[@]}"; do
  if [[ -n "$c" && -x "$c" ]]; then NAVEGADOR="$c"; break; fi
done

if [[ -z "$NAVEGADOR" ]]; then
  echo "No se encontró Chrome ni Edge. Captura las evidencias manualmente."
  exit 1
fi

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
  BASE_ABS="$(pwd -W)"
else
  BASE_ABS="$(pwd)"
fi

# ── Generar tráfico y obtener un trace_id con datos ricos ───────────────────
echo "Generando tráfico para poblar las vistas..."
for i in $(seq 1 40); do
  n=$(printf "%04d" $((i % 40 + 1)))
  curl -fs "http://localhost:8000/order/ORD-$n" > /dev/null 2>&1 || true
done
curl -fs "http://localhost:8000/fail" > /dev/null 2>&1 || true

RESPUESTA=$(curl -fs "http://localhost:8000/order/ORD-0001" 2>/dev/null)
TRACE_ID=$(echo "$RESPUESTA" | python -c "import sys,json;print(json.load(sys.stdin).get('trace_id',''))" 2>/dev/null)

if [[ -z "$TRACE_ID" ]]; then
  echo "No se pudo obtener un trace_id. ¿Está levantado el stack?"
  exit 1
fi

echo "trace_id de la evidencia: $TRACE_ID"
echo "Esperando 15s a que la telemetría llegue a los backends..."
sleep 15

# ── Función de captura ──────────────────────────────────────────────────────
capturar() {
  local nombre="$1"
  local url="$2"
  local espera="${3:-12000}"
  # Alto del viewport: el dashboard completo mide bastante más que una
  # pantalla, y con el valor por defecto se cortan los paneles finales.
  local alto="${4:-1050}"

  echo "  capturando: $nombre"

  # --virtual-time-budget da tiempo a que la SPA renderice antes del disparo;
  # sin él, Grafana y Jaeger aparecerían como pantallas en blanco.
  "$NAVEGADOR" \
    --headless \
    --disable-gpu \
    --no-sandbox \
    --hide-scrollbars \
    --window-size=1680,"$alto" \
    --virtual-time-budget="$espera" \
    --screenshot="${BASE_ABS}/${DESTINO}/${nombre}.png" \
    "$url" > /dev/null 2>&1 || true

  if [[ -f "${DESTINO}/${nombre}.png" ]]; then
    echo "    -> ${DESTINO}/${nombre}.png ($(($(wc -c < "${DESTINO}/${nombre}.png") / 1024)) KB)"
  else
    echo "    -> falló"
  fi
}

echo ""
echo "Capturando evidencias..."

# 1. Traza completa en Jaeger: el árbol con spans de ambos servicios.
capturar "01-jaeger-traza-completa" \
  "http://localhost:16686/trace/${TRACE_ID}" 20000

# 2. Listado de trazas de service-a.
capturar "02-jaeger-busqueda-trazas" \
  "http://localhost:16686/search?service=service-a&limit=20" 18000

# 3. Dashboard de Grafana. kiosk=1 oculta la navegación lateral.
capturar "03-grafana-dashboard-slis" \
  "http://localhost:3000/d/otel-lab-main/otel-lab?orgId=1&from=now-30m&to=now&kiosk=1" 30000 2300

# 4. Explore de Loki filtrado por el trace_id: la correlación log -> traza.
CONSULTA_LOKI=$(python -c "
import json, urllib.parse
panes = {'ev': {'datasource': 'loki',
                'queries': [{'refId': 'A', 'datasource': {'type': 'loki', 'uid': 'loki'},
                             'expr': '{service_name=~\"service-.+\"} | trace_id = \`${TRACE_ID}\`',
                             'queryType': 'range'}],
                'range': {'from': 'now-30m', 'to': 'now'}}}
print(urllib.parse.quote(json.dumps(panes)))
" 2>/dev/null)

capturar "04-grafana-explore-logs-correlacionados" \
  "http://localhost:3000/explore?orgId=1&schemaVersion=1&panes=${CONSULTA_LOKI}" 25000

# 5. Targets de Prometheus: demuestra que todas las fuentes están activas.
capturar "05-prometheus-targets" \
  "http://localhost:9090/targets" 12000

# ── Registro de la evidencia ────────────────────────────────────────────────
cat > "${DESTINO}/README.md" <<MD
# Evidencias del laboratorio

Capturas generadas automáticamente por \`scripts/capturar-evidencias.sh\`.

**trace_id de referencia:** \`${TRACE_ID}\`

| Archivo | Qué demuestra |
|---|---|
| \`01-jaeger-traza-completa.png\` | Traza con spans de service-a **y** service-b bajo un único trace_id: prueba de la propagación W3C TraceContext |
| \`02-jaeger-busqueda-trazas.png\` | Listado de trazas con sus latencias y relación de servicios |
| \`03-grafana-dashboard-slis.png\` | Dashboard: 4 SLIs, CPU/memoria por contenedor y errores del OTel Collector |
| \`04-grafana-explore-logs-correlacionados.png\` | Logs de Loki filtrados por el trace_id: correlación log ↔ traza |
| \`05-prometheus-targets.png\` | Targets de scraping activos |

Para reproducirlas con el estado actual del sistema:

\`\`\`bash
docker compose up -d --build
bash scripts/capturar-evidencias.sh
\`\`\`
MD

echo ""
echo "Evidencias en ${DESTINO}/"
echo "trace_id de referencia: ${TRACE_ID}"
