#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# capturar-evidencias-chaos.sh — Capturas del Game Day
#
# Fotografía el estado de los backends de observabilidad DESPUÉS de ejecutar
# los experimentos, con una ventana temporal que abarca los tres. Los picos de
# latencia y de CPU siguen en Prometheus, de modo que el dashboard muestra el
# incidente completo de principio a fin.
#
# Uso:  bash chaos/capturar-evidencias-chaos.sh
# ════════════════════════════════════════════════════════════════════════════

set -uo pipefail
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DESTINO="chaos/evidencias"
mkdir -p "$DESTINO"

# Ventana que cubre los tres experimentos.
DESDE="${DESDE:-now-2h}"
HASTA="${HASTA:-now}"

CANDIDATOS=(
  "/c/Program Files/Google/Chrome/Application/chrome.exe"
  "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"
  "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
  "$(command -v google-chrome 2>/dev/null || true)"
)

NAVEGADOR=""
for c in "${CANDIDATOS[@]}"; do
  if [[ -n "$c" && -x "$c" ]]; then NAVEGADOR="$c"; break; fi
done
[[ -z "$NAVEGADOR" ]] && { echo "No se encontró Chrome ni Edge."; exit 1; }

BASE_ABS="$(pwd -W 2>/dev/null || pwd)"

capturar() {
  local nombre="$1" url="$2" espera="${3:-15000}" alto="${4:-1100}"
  echo "  capturando: $nombre"
  "$NAVEGADOR" --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --window-size=1680,"$alto" --virtual-time-budget="$espera" \
    --screenshot="${BASE_ABS}/${DESTINO}/${nombre}.png" "$url" > /dev/null 2>&1 || true
  if [[ -f "${DESTINO}/${nombre}.png" ]]; then
    echo "    -> ${DESTINO}/${nombre}.png ($(($(wc -c < "${DESTINO}/${nombre}.png") / 1024)) KB)"
  else
    echo "    -> falló"
  fi
}

echo "Capturando evidencias del Game Day (ventana ${DESDE} → ${HASTA})..."
echo ""

# 1. Dashboard completo: el incidente de principio a fin en los cuatro SLIs,
#    el consumo de recursos y la salud del Collector.
capturar "chaos-01-dashboard-incidente" \
  "http://localhost:3000/d/otel-lab-main/otel-lab?orgId=1&from=${DESDE}&to=${HASTA}&kiosk=1" \
  32000 2300

# 2. Panel de CPU aislado: el pico de stress-ng del experimento 2.
capturar "chaos-02-cpu-stress-ng" \
  "http://localhost:3000/d/otel-lab-main/otel-lab?orgId=1&from=${DESDE}&to=${HASTA}&viewPanel=6&kiosk=1" \
  22000 900

# 3. Panel de latencia aislado: los tres picos, uno por experimento.
capturar "chaos-03-latencia-percentiles" \
  "http://localhost:3000/d/otel-lab-main/otel-lab?orgId=1&from=${DESDE}&to=${HASTA}&viewPanel=2&kiosk=1" \
  22000 900

# 4. Logs de degradación: la prueba de que el fallback actuó durante E3.
# Panel dedicado del dashboard (id 12) con la consulta ya filtrada. Se usa en
# lugar de Grafana Explore porque construir la URL de Explore con una consulta
# LogQL preaplicada resultó frágil: Grafana ignoraba el parámetro y abría el
# datasource por defecto. Un panel versionado es además reproducible.
capturar "chaos-04-logs-degradacion"   "http://localhost:3000/d/otel-lab-main/otel-lab?orgId=1&from=${DESDE}&to=${HASTA}&viewPanel=12&kiosk=1"   25000 1000

# 5. Jaeger: trazas del periodo, donde se ven las de 5 s del experimento 3.
capturar "chaos-05-jaeger-trazas-lentas" \
  "http://localhost:16686/search?service=service-a&limit=30&lookback=2h" \
  20000 1100

# ── Registro de las evidencias ──────────────────────────────────────────────
cat > "${DESTINO}/README.md" <<'MD'
# Evidencias del Game Day

Capturas generadas por `chaos/capturar-evidencias-chaos.sh` tras ejecutar los
tres experimentos. La ventana temporal abarca los tres, de modo que el
dashboard muestra el incidente completo.

| Archivo | Qué demuestra |
|---|---|
| `chaos-01-dashboard-incidente.png` | Los cuatro SLIs durante los tres experimentos: picos de latencia, consumo de CPU y salud del Collector |
| `chaos-02-cpu-stress-ng.png` | Experimento 2: la CPU de service-b saturando su cuota con stress-ng |
| `chaos-03-latencia-percentiles.png` | Los tres picos de latencia, uno por experimento |
| `chaos-04-logs-degradacion.png` | Experimento 3: logs `service-b inalcanzable`, prueba de que el fallback actuó |
| `chaos-05-jaeger-trazas-lentas.png` | Trazas del periodo, incluidas las de ~5 s provocadas por el timeout |

Reproducir:

```bash
docker compose -f docker-compose.yaml -f docker-compose.chaos.yaml up -d
bash chaos/experimentos/e1-latencia-red.sh
bash chaos/experimentos/e2-cpu-exhaustion.sh
bash chaos/experimentos/e3-network-partition.sh
bash chaos/capturar-evidencias-chaos.sh
```
MD

echo ""
echo "Evidencias en ${DESTINO}/"
