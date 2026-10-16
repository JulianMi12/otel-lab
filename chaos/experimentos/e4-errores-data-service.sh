#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# EXPERIMENTO 4 — 10 % de errores en data-service
#
# HIPOTESIS          Con un 10 % de fallos en data-service, la disponibilidad
#                    de /order se mantiene en el 100 % y el p99 no sube mas de
#                    un 20 % sobre la linea base, porque la analitica es una
#                    dependencia OPCIONAL y service-a la trata como tal.
#
# TIPO DE FALLO      error de aplicacion (5xx deterministico por probabilidad)
# OBJETIVO           data-service
# RADIO DE IMPACTO   un unico contenedor; service-b y la base no se tocan
# DURACION           180 s
# ROLLBACK           automatico: CHAOS_ERROR_RATE vuelve a 0 al salir
#
# POR QUE ESTE EXPERIMENTO
#
#   Los tres experimentos del Game Day anterior atacaban a service-b, que es
#   una dependencia critica. Este ataca a una OPCIONAL, y la pregunta que
#   responde es distinta: no "¿aguanta el sistema?" sino "¿esta bien clasificada
#   la dependencia?".
#
#   Una dependencia marcada como opcional en el codigo pero que en la practica
#   tumba la peticion es uno de los fallos de diseno mas caros que existen,
#   porque solo se manifiesta el dia que esa dependencia falla de verdad. La
#   unica forma de comprobar la clasificacion es romperla a proposito.
#
# EQUIVALENCIAS
#
#   Chaos Mesh     PodChaos { action: pod-failure } o HTTPChaos { abort }
#   LitmusChaos    pod-http-status-code con status_code 503 y toxicity 10
#   Istio          VirtualService con fault.abort, en k8s/50-chaos-istio.yaml
#
#   La version de malla hace lo mismo SIN tocar el proceso: el 503 lo genera
#   el sidecar. Las dos coexisten en el repositorio porque responden a
#   preguntas distintas (ver docs/service-mesh.md).
# ════════════════════════════════════════════════════════════════════════════

source "$(dirname "${BASH_SOURCE[0]}")/../comun.sh"

TASA_ERROR="${TASA_ERROR:-0.1}"
DURACION="${DURACION:-180}"
DATA_SERVICE="${DATA_SERVICE:-http://localhost:8002}"
CAOS_ACTIVO=0

# ── Rollback ────────────────────────────────────────────────────────────────
rollback() {
  detener_carga
  if [[ $CAOS_ACTIVO -eq 1 ]]; then
    ambar "  [ROLLBACK] devolviendo CHAOS_ERROR_RATE a 0..."
    CHAOS_ERROR_RATE=0 docker compose up -d data-service > /dev/null 2>&1
    sleep 8
    local estado
    estado=$(curl -s -m 5 "${DATA_SERVICE}/chaos/status" 2>/dev/null)
    verde "  [ROLLBACK] caos retirado — ${estado:-sin respuesta}"
    CAOS_ACTIVO=0
  else
    echo "  [ROLLBACK] no habia caos activo (nada que revertir)"
  fi
}
trap rollback EXIT INT TERM

# ════════════════════════════════════════════════════════════════════════════
fase "EXPERIMENTO 4 — 10 % de errores en data-service"
echo "  Hipotesis: la disponibilidad de /order no se mueve porque la"
echo "             analitica es una dependencia opcional."
echo "  Tasa de error inyectada: $(python -c "print(int($TASA_ERROR*100))") %"
echo "  Duracion: ${DURACION}s"

# ── SOT ─────────────────────────────────────────────────────────────────────
fase "[SOT] Estado estable previo"

if ! curl -fs -m 5 "${DATA_SERVICE}/health" > /dev/null 2>&1; then
  rojo "  data-service no responde en ${DATA_SERVICE}"
  rojo "  levantalo con: docker compose up -d data-service"
  exit 1
fi
verde "  data-service responde"

# Reinicio de calentamiento. Activar el caos obliga a recrear el contenedor,
# y un contenedor recien arrancado tiene el pool de conexiones vacio y el
# interprete frio: en la primera version de este experimento eso disparo el
# p99 a 4.600 ms durante el primer medio minuto y contamino la medicion
# entera, atribuyendo a la inyeccion de errores una latencia que era del
# reinicio. Reiniciando tambien antes de la linea base, los dos tramos se
# miden sobre el mismo estado y la comparacion es honesta.
echo "  reiniciando data-service para igualar condiciones..."
docker compose up -d --force-recreate data-service > /dev/null 2>&1
sleep 10

# 3 req/s, no 8. Medido en este equipo, el codo del sistema esta entre 3 y 4:
#
#     3 req/s  ->  p99   885 ms   dentro del SLO de 1.000 ms
#     5 req/s  ->  p99 2.272 ms   fuera
#
# service-a corre con un unico worker de uvicorn, asi que por encima de ese
# ritmo las peticiones se encolan. Un experimento lanzado sobre un sistema ya
# saturado no mide el fallo inyectado: mide la cola.
iniciar_carga "${RPS:-3}" || exit 1

# El estado estable se verifica BAJO CARGA, no en reposo. Comprobarlo sin
# trafico es lo que dejo pasar una linea base con el p99 a 3.904 ms: sin
# peticiones, el sistema siempre parece sano.
# 90 s, no 45: la ventana de 1 minuto con la que se comprueba el SLO no debe
# solaparse con el reinicio de calentamiento. Con 45 s el probe vio un p99 de
# 1.980 ms que era el arranque en frio, no el regimen de la carga.
echo "  estabilizando la carga (90 s)..."
sleep 90
probe_steady_state 5 || exit 1

echo "  recogiendo linea base (90 s)..."
# La ventana se marca y se mide ENTERA al final. Una muestra instantanea del
# p99 no representa la fase: dentro de una misma fase estable el valor oscila
# mas del doble (ver el comentario de sli_fase en comun.sh).
T_BASE_INI=$(date +%s)
sleep 90
T_BASE_FIN=$(date +%s)

P99_BASE=$(sli_fase "$(expr_p99 service-a)" "$T_BASE_INI" "$T_BASE_FIN")
P95_BASE=$(sli_fase "$(expr_p95 service-a)" "$T_BASE_INI" "$T_BASE_FIN")
DISP_BORDE_BASE=$(sli_fase "$(expr_disponibilidad service-a)" "$T_BASE_INI" "$T_BASE_FIN")
TPS_BASE=$(sli_fase "$(expr_throughput service-a)" "$T_BASE_INI" "$T_BASE_FIN")
DISP_BASE=$(sli_disponibilidad 1m)

echo "  p99                      ${P99_BASE:-n/d} ms   (mediana de la fase)"
echo "  p95                      ${P95_BASE:-n/d} ms"
echo "  disponibilidad /order    ${DISP_BORDE_BASE:-n/d} %"
echo "  disponibilidad agregada  ${DISP_BASE:-n/d} %"
echo "  throughput               ${TPS_BASE:-n/d} req/s"

# ── Inyeccion ───────────────────────────────────────────────────────────────
fase "[CHAOS] Inyectando ${TASA_ERROR} de tasa de error"

echo "  equivalente en Kubernetes:"
echo "    HTTPChaos { target: Response, abort: true, percent: $(python -c "print(int($TASA_ERROR*100))") }"
echo

CHAOS_ERROR_RATE="$TASA_ERROR" docker compose up -d data-service > /dev/null 2>&1
CAOS_ACTIVO=1

# Espera activa en vez de `sleep` fijo. El contenedor recreado tarda entre 10
# y 30 s en estar listo segun la carga de la maquina, y con un sleep de 10 el
# experimento abortaba de forma intermitente: un fallo que depende del humor
# del equipo es peor que uno constante, porque parece aleatorio.
ESTADO=""
for _ in $(seq 1 30); do
  ESTADO=$(curl -s -m 5 "${DATA_SERVICE}/chaos/status" 2>/dev/null)
  [[ -n "$ESTADO" ]] && break
  sleep 2
done

if [[ -z "$ESTADO" ]]; then
  rojo "  data-service no respondio tras 60 s desde el reinicio"
  exit 1
fi
verde "  caos activo — ${ESTADO}"

INICIO_CAOS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── DuringChaos ─────────────────────────────────────────────────────────────
fase "[DuringChaos] Deteccion"

# El umbral se pone sobre los errores de DATA-SERVICE, no sobre los de
# service-a. Es una decision deliberada: si la hipotesis es correcta,
# service-a no registrara ni un solo error, de modo que una sonda sobre
# service-a no detectaria nunca el fallo y el MTTD saldria infinito.
#
# Que haga falta observar el servicio degradado para ver la degradacion es,
# en si mismo, el resultado interesante del experimento: el fallback funciona
# tan bien que el incidente se vuelve invisible desde el borde.
medir_mttd \
  "sum(rate(http_requests_total{source=\"collector\",service=\"data-service\",status=\"5xx\"}[1m])) or vector(0)" \
  "0.05" 120
MTTD=$(cat /tmp/mttd_resultado 2>/dev/null || echo "-1")

# Se descartan los primeros 60 s: activar el caos recrea el contenedor, y un
# contenedor frio disparo el p99 a 4.800 ms durante medio minuto en una
# ejecucion anterior. Lo que interesa es el regimen estable del fallo.
echo "  descartando el transitorio del reinicio (60 s)..."
sleep 60
T_CAOS_INI=$(date +%s)

echo "  observando el regimen estable durante $((DURACION - 60))s..."
sleep $((DURACION - 60))
T_CAOS_FIN=$(date +%s)

P99_CAOS=$(sli_fase "$(expr_p99 service-a)" "$T_CAOS_INI" "$T_CAOS_FIN")
P95_CAOS=$(sli_fase "$(expr_p95 service-a)" "$T_CAOS_INI" "$T_CAOS_FIN")
DISP_BORDE_CAOS=$(sli_fase "$(expr_disponibilidad service-a)" "$T_CAOS_INI" "$T_CAOS_FIN")
TPS_CAOS=$(sli_fase "$(expr_throughput service-a)" "$T_CAOS_INI" "$T_CAOS_FIN")
DISP_CAOS=$(sli_disponibilidad 1m)

# Errores del servicio degradado frente a errores vistos por el cliente.
# La diferencia entre estas dos cifras ES el valor del fallback.
ERR_DATA=$(sli_fase "$(expr_error_rate data-service)" "$T_CAOS_INI" "$T_CAOS_FIN")
ERR_BORDE=$(sli_fase "$(expr_error_rate service-a)" "$T_CAOS_INI" "$T_CAOS_FIN")

echo
echo "  p99                      ${P99_CAOS:-n/d} ms   (mediana de la fase)"
echo "  disponibilidad /order    ${DISP_BORDE_CAOS:-n/d} %   <- decide el veredicto"
echo "  disponibilidad agregada  ${DISP_CAOS:-n/d} %   <- solo contexto"
echo "  errores en data-service  ${ERR_DATA:-n/d} %"
echo "  errores vistos por el    ${ERR_BORDE:-n/d} %"
echo "    cliente de /order"

FIN_CAOS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Rollback y EOT ──────────────────────────────────────────────────────────
fase "[EOT] Rollback y recuperacion"

rollback
trap 'detener_carga' EXIT INT TERM

if [[ -n "$P99_BASE" ]]; then
  probe_recuperacion "$P99_BASE" 1.5 120
  RECUPERACION=$(cat /tmp/recuperacion_resultado 2>/dev/null || echo "-1")
else
  RECUPERACION="-1"
fi

P99_POST=$(sli_p99 1m)
DISP_POST=$(sli_disponibilidad 1m)

detener_carga

# ── Veredicto ───────────────────────────────────────────────────────────────
fase "Veredicto"

VEREDICTO=$(python - "$DISP_BORDE_CAOS" "$P99_BASE" "$P99_CAOS" "$ERR_DATA" <<'PY'
import sys

def num(v, por_defecto=None):
    try:
        return float(v)
    except (TypeError, ValueError):
        return por_defecto

# argv[1] es la disponibilidad DEL BORDE, no la agregada. La distincion
# decide el veredicto: con la agregada, E4 concluia que data-service no era
# opcional cuando el cliente no habia visto ni un solo error.
disp  = num(sys.argv[1])
base  = num(sys.argv[2])
caos  = num(sys.argv[3])
errds = num(sys.argv[4])

if None in (disp, base, caos, errds):
    print("INDETERMINADO|faltan metricas para evaluar la hipotesis")
    raise SystemExit

# El fallo tiene que haber ocurrido de verdad: sin errores en data-service no
# hay experimento, solo una ventana de observacion. Se acepta un margen amplio
# porque 180 s de trafico a 8 req/s dan pocas muestras y la proporcion
# observada se separa facilmente del 10 % nominal.
if errds < 3:
    print("INVALIDO|la inyeccion no llego a producir errores (%.1f %%); revisar CHAOS_ERROR_RATE" % errds)
    raise SystemExit

degradacion = 100.0 * (caos - base) / base

if disp >= 99.9 and degradacion <= 20.0:
    print("CONFIRMADA|disponibilidad %.2f %% y p99 +%.1f %%: el fallback aisla el fallo" % (disp, degradacion))
elif disp >= 99.9:
    print("PARCIAL|disponibilidad intacta (%.2f %%) pero el p99 subio un %.1f %%, por encima del 20 %% previsto" % (disp, degradacion))
else:
    print("REFUTADA|la disponibilidad cayo al %.2f %%: data-service NO es opcional en la practica" % disp)
PY
)

ESTADO_HIP="${VEREDICTO%%|*}"
DETALLE="${VEREDICTO#*|}"

case "$ESTADO_HIP" in
  CONFIRMADA)    verde "  HIPOTESIS CONFIRMADA" ;;
  PARCIAL)       ambar "  HIPOTESIS PARCIALMENTE CONFIRMADA" ;;
  REFUTADA)      rojo  "  HIPOTESIS REFUTADA" ;;
  *)             ambar "  RESULTADO ${ESTADO_HIP}" ;;
esac
echo "  ${DETALLE}"
echo

if [[ "$ESTADO_HIP" == "CONFIRMADA" ]]; then
  echo "  Lo que esto demuestra y lo que no:"
  echo
  echo "    SI demuestra  que la clasificacion de data-service como dependencia"
  echo "                  opcional es correcta, y que el fallback funciona."
  echo
  echo "    NO demuestra  que el incidente sea visible. Con el borde al 100 %%,"
  echo "                  ninguna alerta basada en la disponibilidad de /order"
  echo "                  habria saltado. Hace falta una alerta sobre los"
  echo "                  errores de data-service EN SI MISMO, o el fallo"
  echo "                  puede durar dias sin que nadie se entere."
  echo
fi

# ── Presupuesto de error ────────────────────────────────────────────────────
fase "Consumo del presupuesto de error"

python - "$DISP_BORDE_CAOS" "$DURACION" <<'PY'
import sys

SLO = 99.5                      # objetivo de disponibilidad
VENTANA_DIAS = 30

try:
    disp = float(sys.argv[1])
    duracion = float(sys.argv[2])
except (TypeError, ValueError):
    print("  sin datos suficientes para calcular el consumo")
    raise SystemExit

presupuesto_pct = 100.0 - SLO
presupuesto_s = VENTANA_DIAS * 24 * 3600 * presupuesto_pct / 100.0

consumido_s = duracion * (100.0 - disp) / 100.0
consumido_pct = 100.0 * consumido_s / presupuesto_s if presupuesto_s else 0.0

# Tasa de quemado: cuantas veces mas rapido de lo sostenible se esta gastando
# el presupuesto. 1.0 significa que, a ese ritmo, el presupuesto duraria
# exactamente los 30 dias.
tasa = ((100.0 - disp) / presupuesto_pct) if presupuesto_pct else 0.0

print("  SLO de disponibilidad      %.2f %%" % SLO)
print("  Presupuesto de error (30d) %.0f s  (%.2f %%)" % (presupuesto_s, presupuesto_pct))
print("  Consumido en este          %.1f s  (%.3f %% del presupuesto)" % (consumido_s, consumido_pct))
print("    experimento")
print("  Tasa de quemado            %.2fx" % tasa)
print()

if tasa >= 14.4:
    print("  A este ritmo el presupuesto mensual se agotaria en %.1f dias." %
          (VENTANA_DIAS / tasa))
    print("  Supera el umbral de quemado rapido del SRE Workbook (14,4x): la")
    print("  respuesta correcta seria congelar despliegues de funcionalidad.")
elif tasa >= 1.0:
    print("  El consumo supera lo sostenible, pero sin urgencia: a este ritmo")
    print("  el presupuesto duraria %.1f dias de los 30 previstos." % (VENTANA_DIAS / tasa))
else:
    print("  Consumo por debajo de lo sostenible. El experimento cabe de sobra")
    print("  dentro del presupuesto: ejecutarlo en produccion seria defendible.")
PY

# ── Persistencia ────────────────────────────────────────────────────────────
echo
guardar_resultado "e4-errores-data-service.json" \
  "experimento=E4 - Errores en dependencia opcional" \
  "tipo_fallo=application error (5xx probabilistico)" \
  "herramienta=CHAOS_ERROR_RATE (inyeccion en el propio servicio)" \
  "objetivo=data-service" \
  "tasa_error_inyectada=$TASA_ERROR" \
  "duracion_s=$DURACION" \
  "inicio_caos=$INICIO_CAOS" \
  "fin_caos=$FIN_CAOS" \
  "p99_base_ms=${P99_BASE:-}" \
  "p99_chaos_ms=${P99_CAOS:-}" \
  "p99_post_ms=${P99_POST:-}" \
  "p95_base_ms=${P95_BASE:-}" \
  "p95_chaos_ms=${P95_CAOS:-}" \
  "disponibilidad_agregada_base=${DISP_BASE:-}" \
  "disponibilidad_agregada_chaos=${DISP_CAOS:-}" \
  "disponibilidad_borde_base=${DISP_BORDE_BASE:-}" \
  "disponibilidad_borde_chaos=${DISP_BORDE_CAOS:-}" \
  "disponibilidad_post=${DISP_POST:-}" \
  "throughput_base=${TPS_BASE:-}" \
  "throughput_chaos=${TPS_CAOS:-}" \
  "error_rate_data_service_pct=${ERR_DATA:-}" \
  "error_rate_borde_pct=${ERR_BORDE:-}" \
  "mttd_s=${MTTD}" \
  "recuperacion_s=${RECUPERACION}" \
  "hipotesis=$ESTADO_HIP" \
  "detalle=$DETALLE"

verde "Experimento 4 completado"
