#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# comun.sh — Funciones compartidas por los experimentos de caos
#
# Implementa el ciclo de un Game Day siguiendo el modelo de probes de
# LitmusChaos, que separa la verificación en tres momentos:
#
#   SOT  (Start Of Test)  → el sistema está sano ANTES de inyectar el fallo
#   DuringChaos           → se detecta la anomalía; aquí se mide el MTTD
#   EOT  (End Of Test)    → el sistema se recupera tras el rollback
#
# Sin la fase SOT un experimento no prueba nada: si el sistema ya estaba
# degradado, cualquier medición posterior es atribuible al estado previo y no
# al fallo inyectado.
# ════════════════════════════════════════════════════════════════════════════

set -uo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

PROM="${PROM:-http://localhost:9090}"
SERVICE_A="${SERVICE_A:-http://localhost:8000}"

# Se trabaja desde la raiz del repositorio con rutas RELATIVAS: Python bajo
# Windows no interpreta las rutas estilo MSYS (/c/Users/...) que devuelve pwd
# en Git Bash, y al guardar los resultados fallaria con FileNotFoundError.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
RESULTADOS="chaos/resultados"
mkdir -p "$RESULTADOS"

# ── Salida con color ────────────────────────────────────────────────────────
azul()  { printf '\033[1;34m%s\033[0m\n' "$1"; }
verde() { printf '\033[1;32m%s\033[0m\n' "$1"; }
rojo()  { printf '\033[1;31m%s\033[0m\n' "$1"; }
ambar() { printf '\033[1;33m%s\033[0m\n' "$1"; }

fase() {
  echo ""
  azul "──────────────────────────────────────────────────────────────"
  azul "  $1"
  azul "──────────────────────────────────────────────────────────────"
}

# ── Consulta instantánea a Prometheus ───────────────────────────────────────
promq() {
  curl -s -G "${PROM}/api/v1/query" --data-urlencode "query=$1" 2>/dev/null |
    python -c "
import sys, json
try:
    r = json.load(sys.stdin)['data']['result']
    v = r[0]['value'][1] if r else ''
    print('%.3f' % float(v) if v not in ('', 'NaN') else '')
except Exception:
    print('')
" 2>/dev/null
}

# ── SLIs del sistema, con la ventana indicada ───────────────────────────────
sli_p99() {
  promq "histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{source=\"collector\"}[${1:-2m}]))) * 1000"
}
sli_p95() {
  promq "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{source=\"collector\"}[${1:-2m}]))) * 1000"
}
sli_disponibilidad() {
  promq "100 * (1 - (sum(rate(http_requests_total{source=\"collector\",status=\"5xx\"}[${1:-2m}])) or vector(0)) / clamp_min(sum(rate(http_requests_total{source=\"collector\"}[${1:-2m}])), 0.0001))"
}
sli_throughput() {
  promq "sum(rate(http_requests_total{source=\"collector\"}[${1:-2m}]))"
}
cpu_contenedor() {
  promq "max(container_cpu_utilization_ratio{container_name=\"$1\"})"
}
# Contador de llamadas degradadas: la señal de que el fallback actuó.
fallbacks() {
  promq "sum(service_b_calls_total{source=\"collector\",result=\"unavailable\"}) or vector(0)"
}

# ── Generador de carga en segundo plano ─────────────────────────────────────
# Tráfico constante durante todo el experimento: sin carga, las métricas no
# tienen muestras y el fallo inyectado sería invisible para el pipeline.
PID_CARGA=""

iniciar_carga() {
  local rps="${1:-12}"
  local pausa
  pausa=$(python -c "print(1.0/$rps)")
  (
    while true; do
      for _ in 1 2 3; do
        n=$(printf "%04d" $((RANDOM % 40 + 1)))
        curl -fs -m 20 "${SERVICE_A}/order/ORD-${n}" > /dev/null 2>&1 &
      done
      sleep "$pausa"
    done
  ) &
  PID_CARGA=$!
  echo "  generador de carga activo (~${rps} req/s, pid ${PID_CARGA})"
}

detener_carga() {
  if [[ -n "$PID_CARGA" ]]; then
    kill "$PID_CARGA" 2>/dev/null || true
    wait "$PID_CARGA" 2>/dev/null || true
    PID_CARGA=""
    echo "  generador de carga detenido"
  fi
}

# ── Probe SOT: ¿el sistema está sano antes de empezar? ──────────────────────
probe_steady_state() {
  local intentos="${1:-5}"
  local ok=0

  echo "  verificando salud de los servicios..."
  for ((i = 1; i <= intentos; i++)); do
    local ca cb
    ca=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "${SERVICE_A}/health" 2>/dev/null)
    cb=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "http://localhost:8001/health" 2>/dev/null)
    if [[ "$ca" == "200" && "$cb" == "200" ]]; then
      ok=$((ok + 1))
    fi
    sleep 1
  done

  if [[ $ok -eq $intentos ]]; then
    verde "  [SOT] Steady state confirmado: ${ok}/${intentos} health checks correctos"
    return 0
  fi

  rojo "  [SOT] Steady state NO confirmado: sólo ${ok}/${intentos} correctos"
  rojo "        El experimento se aborta: medir sobre un sistema ya degradado"
  rojo "        no permitiria atribuir el impacto al fallo inyectado."
  return 1
}

# ── Probe DuringChaos: cuánto tarda la observabilidad en delatar el fallo ───
# Equivale al promProbe de LitmusChaos en modo DuringChaos.
medir_mttd() {
  local metrica="$1" umbral="$2" limite="${3:-120}"
  local inicio ahora valor
  inicio=$(date +%s)

  echo "  midiendo MTTD (umbral: ${metrica} > ${umbral}, límite ${limite}s)..."

  while true; do
    valor=$(promq "$metrica")
    ahora=$(date +%s)
    local transcurrido=$((ahora - inicio))

    if [[ -n "$valor" ]] && (( $(python -c "print(1 if $valor > $umbral else 0)") )); then
      verde "  [DuringChaos] Anomalía detectada a los ${transcurrido}s (valor: ${valor})"
      echo "$transcurrido" > /tmp/mttd_resultado
      return 0
    fi

    if (( transcurrido >= limite )); then
      ambar "  [DuringChaos] Sin detección tras ${limite}s (último valor: ${valor:-n/d})"
      echo "-1" > /tmp/mttd_resultado
      return 1
    fi
    sleep 5
  done
}

# ── Probe EOT: ¿vuelve el sistema a su estado normal? ───────────────────────
probe_recuperacion() {
  local p99_base="$1" margen="${2:-2.0}"
  local limite="${3:-120}"
  local inicio ahora p99
  inicio=$(date +%s)
  local techo
  techo=$(python -c "print($p99_base * $margen)")

  echo "  esperando recuperación (p99 por debajo de ${techo} ms)..."

  while true; do
    p99=$(sli_p99 1m)
    ahora=$(date +%s)
    local transcurrido=$((ahora - inicio))

    if [[ -n "$p99" ]] && (( $(python -c "print(1 if $p99 < $techo else 0)") )); then
      verde "  [EOT] Sistema recuperado a los ${transcurrido}s (p99: ${p99} ms)"
      echo "$transcurrido" > /tmp/recuperacion_resultado
      return 0
    fi

    if (( transcurrido >= limite )); then
      ambar "  [EOT] Sin recuperación completa tras ${limite}s (p99: ${p99:-n/d} ms)"
      echo "-1" > /tmp/recuperacion_resultado
      return 1
    fi
    sleep 5
  done
}

# ── Instalación de las herramientas de fault ────────────────────────────────
# Se instalan sobre el contenedor en ejecución, no en la imagen: la imagen que
# llegaria a produccion no debe contener utilidades de ataque.
instalar_herramientas() {
  local contenedor="$1"; shift
  local paquetes="$*"

  echo "  instalando [${paquetes}] en ${contenedor}..."

  # Se instala siempre: apt-get es idempotente y comprobar sólo un binario
  # daba falsos positivos. Ocurrió con procps: stress-ng estaba presente, así
  # que la función daba por buena la instalación, pero faltaban pgrep y pkill
  # y el rollback del experimento no podía ejecutarse.
  docker exec -u root "$contenedor" bash -c \
    "apt-get update -qq > /dev/null 2>&1 && apt-get install -y -qq ${paquetes} > /dev/null 2>&1" \
    && verde "  herramientas instaladas" \
    || { rojo "  fallo instalando herramientas"; return 1; }
}

# ── Registro del resultado ──────────────────────────────────────────────────
guardar_resultado() {
  local archivo="$RESULTADOS/$1"; shift
  python - "$archivo" "$@" <<'PY'
import json, sys
archivo = sys.argv[1]
datos = {}
for par in sys.argv[2:]:
    if "=" in par:
        k, v = par.split("=", 1)
        try:
            datos[k] = float(v) if v.replace(".", "").replace("-", "").isdigit() else v
        except Exception:
            datos[k] = v
with open(archivo, "w", encoding="utf-8") as fh:
    json.dump(datos, fh, indent=2, ensure_ascii=False)
print("  resultado guardado en " + archivo)
PY
}

# Garantiza que la carga se detiene aunque el script muera a medio camino.
trap 'detener_carga' EXIT INT TERM
