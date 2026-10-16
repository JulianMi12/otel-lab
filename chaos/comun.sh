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

# Objetivos de nivel de servicio. Los mismos que usan el panel de Grafana,
# aiops/detector.py y terraform/observabilidad. Aqui hacen falta porque el
# probe SOT los necesita: "estado estable" significa DENTRO del SLO, no
# simplemente "responde".
SLO_P99_MS="${SLO_P99_MS:-1000}"
SLO_DISPONIBILIDAD="${SLO_DISPONIBILIDAD:-99.5}"
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
# Disponibilidad de UN servicio concreto.
#
# La de arriba agrega los tres y NO sirve para juzgar una hipotesis: mezcla el
# borde con sus dependencias. Si data-service falla un 10 % y los tres reciben
# trafico parecido, la cifra agregada baja un 3 % aunque el cliente no haya
# visto ni un solo error. Paso exactamente eso en E4, donde el veredicto salio
# "hipotesis refutada" con la disponibilidad de /order intacta al 100 %.
#
# El SLO se promete sobre el borde, no sobre la media de la arquitectura.
sli_disponibilidad_servicio() {
  local servicio="$1" ventana="${2:-2m}"
  promq "100 * (1 - (sum(rate(http_requests_total{source=\"collector\",service=\"${servicio}\",status=\"5xx\"}[${ventana}])) or vector(0)) / clamp_min(sum(rate(http_requests_total{source=\"collector\",service=\"${servicio}\"}[${ventana}])), 0.0001))"
}

sli_throughput() {
  promq "sum(rate(http_requests_total{source=\"collector\"}[${1:-2m}]))"
}
# ── SLI de una FASE completa, no de un instante ─────────────────────────────
#
# Las funciones de arriba devuelven el valor de la metrica en el momento en que
# se las llama. Para un contador eso vale; para un p99, no.
#
# Medido en E4, el p99 de service-a dentro de una unica fase ESTABLE recorrio
# este rango:
#
#     base:   74 · 215 · 357 · 428 · 438 · 393 · 268 ms
#     caos:  235 · 247 · 248 · 420 · 440 · 450 · 366 · 392 · 427 · 434 · 461 ms
#
# Mas del doble de variacion sin que nada cambiara. Comparar una muestra de
# cada fase da lo que toque: con las muestras que salieron, el veredicto fue
# "+62 % de p99"; con otras dos igual de validas habria salido "-45 %".
#
# sli_fase consulta el RANGO completo entre dos marcas de tiempo y devuelve la
# mediana de la serie, que es estable frente a esa oscilacion.
#
#   sli_fase <expresion_promql> <epoch_inicio> <epoch_fin> [paso]
sli_fase() {
  local expr="$1" desde="$2" hasta="$3" paso="${4:-15}"
  curl -s -G "${PROM}/api/v1/query_range"     --data-urlencode "query=${expr}"     --data-urlencode "start=${desde}"     --data-urlencode "end=${hasta}"     --data-urlencode "step=${paso}" 2>/dev/null |
    python -c "
import sys, json, statistics
try:
    r = json.load(sys.stdin)['data']['result']
    vals = [float(v) for _, v in r[0]['values']] if r else []
    vals = [v for v in vals if v == v]   # descarta NaN
    print('%.3f' % statistics.median(vals) if vals else '')
except Exception:
    print('')
" 2>/dev/null
}

# Expresiones listas para pasar a sli_fase. Todas filtran por servicio: el SLO
# se promete sobre un servicio concreto, no sobre la media de la arquitectura.
expr_p99() {
  echo "histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{source=\"collector\",service=\"$1\"}[1m]))) * 1000"
}
expr_p95() {
  echo "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{source=\"collector\",service=\"$1\"}[1m]))) * 1000"
}
expr_disponibilidad() {
  echo "100 * (1 - (sum(rate(http_requests_total{source=\"collector\",service=\"$1\",status=\"5xx\"}[1m])) or vector(0)) / clamp_min(sum(rate(http_requests_total{source=\"collector\",service=\"$1\"}[1m])), 0.0001))"
}
expr_error_rate() {
  echo "100 * (sum(rate(http_requests_total{source=\"collector\",service=\"$1\",status=\"5xx\"}[1m])) or vector(0)) / clamp_min(sum(rate(http_requests_total{source=\"collector\",service=\"$1\"}[1m])), 0.0001)"
}
expr_throughput() {
  echo "sum(rate(http_requests_total{source=\"collector\",service=\"$1\"}[1m]))"
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
  # Un unico proceso de Python, no un bucle de curl en segundo plano.
  # El bucle anterior lanzaba un proceso por peticion y Git Bash sobre Windows
  # agotaba los recursos de fork a mitad del experimento:
  #   dofork: child -1 ... exit code 0xC0000142
  #   fork: Resource temporarily unavailable
  # Fallaba de forma intermitente segun la carga de la maquina, que es la
  # peor manera de fallar. Ver chaos/generador_carga.py.
  python chaos/generador_carga.py --rps "$rps" --objetivo "$SERVICE_A" &
  PID_CARGA=$!
  sleep 2
  if ! kill -0 "$PID_CARGA" 2>/dev/null; then
    rojo "  el generador de carga no arranco"
    PID_CARGA=""
    return 1
  fi
  echo "  generador de carga activo (~${rps} req/s, pid ${PID_CARGA})"
}

detener_carga() {
  if [[ -n "$PID_CARGA" ]]; then
    # TERM, no KILL: el generador atrapa la senal e imprime cuantas
    # peticiones envio de verdad, que es el dato con el que se comprueba que
    # la carga fue la que se pidio.
    kill -TERM "$PID_CARGA" 2>/dev/null || true
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

  if [[ $ok -ne $intentos ]]; then
    rojo "  [SOT] Steady state NO confirmado: solo ${ok}/${intentos} correctos"
    rojo "        El experimento se aborta: medir sobre un sistema ya degradado"
    rojo "        no permitiria atribuir el impacto al fallo inyectado."
    return 1
  fi

  # Responder 200 no es estar sano.
  #
  # En una ejecucion de E4 el generador de carga saturo el sistema y el p99 de
  # la linea base salio a 3.904 ms contra un SLO de 1.000 ms. Los health checks
  # pasaron los cinco, el experimento siguio adelante y el veredicto fue
  # "hipotesis confirmada" sobre un sistema que ya estaba cuatro veces fuera de
  # objetivo antes de inyectar nada.
  #
  # El estado estable de un Game Day es el estado NORMAL del sistema, y normal
  # significa dentro del SLO. Si no lo esta, lo que toca es arreglar eso, no
  # romperlo mas.
  # Mediana del ultimo minuto y filtrada por el servicio del borde, no una
  # muestra instantanea del agregado. Las dos cosas importan: el p99 oscila
  # mas del doble dentro de una fase estable, y el agregado diluye el borde
  # entre sus dependencias.
  local p99 disp ahora
  ahora=$(date +%s)
  p99=$(sli_fase "$(expr_p99 "${SERVICIO_BORDE:-service-a}")" $((ahora - 60)) "$ahora")
  disp=$(sli_fase "$(expr_disponibilidad "${SERVICIO_BORDE:-service-a}")" $((ahora - 60)) "$ahora")

  if [[ -z "$p99" || -z "$disp" ]]; then
    ambar "  [SOT] Sin metricas suficientes para comprobar el SLO"
    ambar "        Se continua, pero la linea base puede no ser representativa."
    verde "  [SOT] Steady state confirmado: ${ok}/${intentos} health checks correctos"
    return 0
  fi

  local fuera=0
  if (( $(python -c "print(1 if $p99 > $SLO_P99_MS else 0)") )); then
    rojo "  [SOT] p99 en ${p99} ms, por encima del SLO de ${SLO_P99_MS} ms"
    fuera=1
  fi
  if (( $(python -c "print(1 if $disp < $SLO_DISPONIBILIDAD else 0)") )); then
    rojo "  [SOT] disponibilidad en ${disp} %, por debajo del SLO de ${SLO_DISPONIBILIDAD} %"
    fuera=1
  fi

  if [[ $fuera -eq 1 ]]; then
    rojo "        El experimento se aborta: el sistema ya esta fuera de objetivo."
    rojo "        Baja la carga (parametro de iniciar_carga) o revisa por que"
    rojo "        el sistema no cumple su SLO en reposo."
    return 1
  fi

  verde "  [SOT] Steady state confirmado: ${ok}/${intentos} health checks,"
  verde "        p99 ${p99} ms (SLO ${SLO_P99_MS}) y disponibilidad ${disp} % (SLO ${SLO_DISPONIBILIDAD})"
  return 0

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
