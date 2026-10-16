#!/usr/bin/env bash
# Convierte el Plan de Game Day de HTML a PDF con Chrome headless.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

HTML="chaos/plan-gameday.html"
PDF="chaos/plan-gameday.pdf"

[[ -f "$HTML" ]] || { echo "Falta $HTML — ejecuta: python chaos/generar_gameday.py"; exit 1; }

CANDIDATOS=(
  "/c/Program Files/Google/Chrome/Application/chrome.exe"
  "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"
  "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  "$(command -v google-chrome 2>/dev/null || true)"
)
NAVEGADOR=""
for c in "${CANDIDATOS[@]}"; do
  [[ -n "$c" && -x "$c" ]] && { NAVEGADOR="$c"; break; }
done
[[ -z "$NAVEGADOR" ]] && { echo "No se encontró Chrome ni Edge."; exit 1; }

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
  RUTA_HTML="file:///$(pwd -W)/${HTML}"; RUTA_PDF="$(pwd -W)/${PDF}"
else
  RUTA_HTML="file://$(pwd)/${HTML}"; RUTA_PDF="$(pwd)/${PDF}"
fi

echo "Generando PDF..."
MSYS_NO_PATHCONV=1 "$NAVEGADOR" --headless --disable-gpu --no-sandbox \
  --no-pdf-header-footer --print-to-pdf="$RUTA_PDF" "$RUTA_HTML" 2>/dev/null || true

[[ -f "$PDF" ]] && echo "PDF generado: $PDF ($(($(wc -c < "$PDF") / 1024)) KB)" \
  || { echo "La conversión falló."; exit 1; }
