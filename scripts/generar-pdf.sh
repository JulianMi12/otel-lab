#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# generar-pdf.sh — Convierte el reporte técnico de HTML a PDF
#
# Usa Chrome (o Edge) en modo headless, que ya viene instalado en Windows y
# macOS. Así no hace falta instalar pandoc, wkhtmltopdf ni LaTeX para producir
# el entregable.
#
# Uso:
#   python docs/generar_reporte.py   # genera el HTML con los datos del benchmark
#   bash scripts/generar-pdf.sh      # lo convierte a PDF
# ════════════════════════════════════════════════════════════════════════════

set -euo pipefail

cd "$(dirname "$0")/.."

# Acepta el HTML como argumento para poder generar varios informes con el
# mismo script. Sin argumento conserva el comportamiento anterior.
HTML="${1:-docs/reporte-tecnico.html}"
PDF="${HTML%.html}.pdf"

if [[ ! -f "$HTML" ]]; then
  echo "No existe $HTML — ejecuta primero: python docs/generar_reporte.py"
  exit 1
fi

# Candidatos por sistema operativo, en orden de preferencia.
CANDIDATOS=(
  "/c/Program Files/Google/Chrome/Application/chrome.exe"
  "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"
  "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  "$(command -v google-chrome 2>/dev/null || true)"
  "$(command -v chromium 2>/dev/null || true)"
)

NAVEGADOR=""
for c in "${CANDIDATOS[@]}"; do
  if [[ -n "$c" && -x "$c" ]]; then
    NAVEGADOR="$c"
    break
  fi
done

if [[ -z "$NAVEGADOR" ]]; then
  echo "No se encontró Chrome ni Edge."
  echo "Alternativa: abre $HTML en el navegador y usa Ctrl+P → Guardar como PDF."
  exit 1
fi

echo "Navegador: $NAVEGADOR"

# Chrome headless necesita rutas absolutas en formato del sistema operativo.
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
  RUTA_HTML="file:///$(pwd -W)/${HTML}"
  RUTA_PDF="$(pwd -W)/${PDF}"
else
  RUTA_HTML="file://$(pwd)/${HTML}"
  RUTA_PDF="$(pwd)/${PDF}"
fi

echo "Generando PDF..."

# --no-pdf-header-footer evita que Chrome imprima la URL del archivo y la
# fecha del sistema en cada página, que afearía el entregable.
MSYS_NO_PATHCONV=1 "$NAVEGADOR" \
  --headless \
  --disable-gpu \
  --no-sandbox \
  --no-pdf-header-footer \
  --print-to-pdf="$RUTA_PDF" \
  "$RUTA_HTML" 2>/dev/null || true

if [[ -f "$PDF" ]]; then
  TAM=$(wc -c < "$PDF")
  echo "PDF generado: $PDF ($((TAM / 1024)) KB)"
else
  echo "La conversión falló."
  echo "Alternativa: abre $HTML en el navegador y usa Ctrl+P → Guardar como PDF."
  exit 1
fi
