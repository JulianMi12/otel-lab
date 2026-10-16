#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# Modulo B — Escenario controlado para evaluar el detector
#
# No basta con afirmar que el baseline movil reduce el ruido: hay que
# producir una ventana con ruido Y con un incidente real, y comprobar que el
# detector separa los dos. Este script genera exactamente eso.
#
#   Fase 1  BASELINE      7 min de trafico estable. Fija el "normal".
#   Fase 2  RUIDO         75 s de latencia moderada en service-b, sin errores.
#                         Un umbral fijo de 500 ms dispara aqui; la regla
#                         correlacionada no debe hacerlo.
#   Fase 3  CALMA         2 min para que el baseline reabsorba el pico.
#   Fase 4  INCIDENTE     3 min con la base de datos caida. Errores Y latencia
#                         a la vez: el detector tiene que abrir incidente.
#   Fase 5  RECUPERACION  4 min. Verifica que el incidente se cierra solo.
#
# Por que la base de datos y no mas latencia: service-a degrada con elegancia
# ante un fallo de service-b (devuelve el pedido sin inventario, con 200). Una
# latencia aguas abajo, por grande que sea, NUNCA produce errores en
# service-a. El unico fallo que mueve las dos senales a la vez es el de la
# dependencia critica, y eso es precisamente lo que la regla busca.
#
# Rollback: `docker start` de la base en el trap, pase lo que pase.
# ════════════════════════════════════════════════════════════════════════════
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

SERVICE_A="${SERVICE_A:-http://localhost:8000}"
TOXIPROXY="${TOXIPROXY:-http://localhost:8474}"
DB_CONTENEDOR="otel-postgres"
TOXIC="ruido-aiops"
RESULTADOS="aiops/resultados"
PID_CARGA=""

azul()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m  OK  \033[0m %s\n' "$*"; }
ambar() { printf '\033[1;33m  ..  \033[0m %s\n' "$*"; }
rojo()  { printf '\033[1;31m FALLO\033[0m %s\n' "$*" >&2; }

marca() { date -u +%Y-%m-%dT%H:%M:%S; }

# ── Rollback ────────────────────────────────────────────────────────────────
limpiar() {
  echo
  ambar "rollback"
  [[ -n "$PID_CARGA" ]] && { kill "$PID_CARGA" 2>/dev/null; wait "$PID_CARGA" 2>/dev/null; }
  curl -s -X DELETE "${TOXIPROXY}/proxies/service-b/toxics/${TOXIC}" >/dev/null 2>&1
  if ! docker ps --format '{{.Names}}' | grep -q "^${DB_CONTENEDOR}$"; then
    docker start "$DB_CONTENEDOR" >/dev/null 2>&1 && ok "base de datos levantada"
  fi
  ok "estado restaurado"
}
trap limpiar EXIT INT TERM

# ── Generador de carga ──────────────────────────────────────────────────────
# Peticiones secuenciales con pausa fija. Un generador que lanza en paralelo
# sin limite falsea la medicion: cuando el sistema se degrada, el paralelismo
# se dispara y el p99 que se observa es el de la cola del generador, no el del
# servicio.
carga() {
  local rps="$1"
  local pausa
  pausa=$(python -c "print(round(1.0/$rps, 3))")
  (
    while true; do
      n=$(printf "%04d" $((RANDOM % 40 + 1)))
      curl -fs -m 25 "${SERVICE_A}/order/ORD-${n}" >/dev/null 2>&1
      sleep "$pausa"
    done
  ) &
  PID_CARGA=$!
  ok "carga activa (~${rps} req/s, pid ${PID_CARGA})"
}

cuenta_atras() {
  local segundos="$1" etiqueta="$2"
  local fin=$(( $(date +%s) + segundos ))
  while [ "$(date +%s)" -lt "$fin" ]; do
    printf '\r      %s — quedan %3ds ' "$etiqueta" "$(( fin - $(date +%s) ))"
    sleep 5
  done
  printf '\r      %s — completado%*s\n' "$etiqueta" 20 ''
}

# ── Comprobaciones previas ──────────────────────────────────────────────────
azul "Comprobaciones"

curl -fs -m 5 "${SERVICE_A}/health" >/dev/null || { rojo "service-a no responde en ${SERVICE_A}"; exit 1; }
ok "service-a responde"

curl -fs -m 5 "http://localhost:9090/-/healthy" >/dev/null || { rojo "Prometheus no responde"; exit 1; }
ok "Prometheus responde"

HAY_TOXIPROXY=1
if ! curl -fs -m 5 "${TOXIPROXY}/proxies" >/dev/null 2>&1; then
  HAY_TOXIPROXY=0
  ambar "Toxiproxy no esta activo: se omite la fase de ruido"
  ambar "para incluirla:  docker compose -f docker-compose.yaml -f docker-compose.chaos.yaml up -d"
else
  ok "Toxiproxy responde"
fi

docker ps --format '{{.Names}}' | grep -q "^${DB_CONTENEDOR}$" \
  || { rojo "el contenedor ${DB_CONTENEDOR} no esta corriendo"; exit 1; }
ok "base de datos activa"

mkdir -p "$RESULTADOS"
VENTANA_INICIO=$(marca)

echo

# ── Fase 1: baseline ────────────────────────────────────────────────────────
azul "[1/5] Baseline — 7 min de trafico estable"
carga 8
cuenta_atras 420 "fijando el comportamiento normal"
F1_FIN=$(marca)

# ── Fase 2: ruido ───────────────────────────────────────────────────────────
azul "[2/5] Ruido — latencia moderada sin errores"
F2_INICIO=$(marca)

if [ "$HAY_TOXIPROXY" -eq 1 ]; then
  curl -s -X POST "${TOXIPROXY}/proxies/service-b/toxics" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${TOXIC}\",\"type\":\"latency\",\"stream\":\"downstream\",\"toxicity\":1.0,\"attributes\":{\"latency\":700,\"jitter\":80}}" \
    >/dev/null
  ok "700 ms inyectados en service-b (el pedido sigue devolviendo 200)"
  cuenta_atras 75 "generando ruido"
  curl -s -X DELETE "${TOXIPROXY}/proxies/service-b/toxics/${TOXIC}" >/dev/null
  ok "ruido retirado"
else
  ambar "fase omitida"
  cuenta_atras 75 "sin inyeccion"
fi
F2_FIN=$(marca)

# ── Fase 3: calma ───────────────────────────────────────────────────────────
azul "[3/5] Calma — 2 min"
cuenta_atras 120 "dejando que el baseline reabsorba el pico"

# ── Fase 4: incidente ───────────────────────────────────────────────────────
azul "[4/5] Incidente — dependencia critica caida"
F4_INICIO=$(marca)
docker stop "$DB_CONTENEDOR" >/dev/null
ok "base de datos detenida a las ${F4_INICIO}Z"
ambar "service-a devolvera 500 y, en las conexiones nuevas, tardara segundos"
cuenta_atras 180 "incidente en curso"
F4_FIN=$(marca)

# ── Fase 5: recuperacion ────────────────────────────────────────────────────
azul "[5/5] Recuperacion — 4 min"
docker start "$DB_CONTENEDOR" >/dev/null
ok "base de datos levantada a las $(marca)Z"
cuenta_atras 240 "verificando que el incidente se cierra solo"

kill "$PID_CARGA" 2>/dev/null; wait "$PID_CARGA" 2>/dev/null; PID_CARGA=""
VENTANA_FIN=$(marca)

# ── Analisis ────────────────────────────────────────────────────────────────
echo
azul "Analisis"

cat > "${RESULTADOS}/ventanas.json" <<JSON
{
  "escenario": "Modulo B - deteccion de anomalias",
  "ventana": { "inicio": "${VENTANA_INICIO}", "fin": "${VENTANA_FIN}" },
  "fases": [
    { "nombre": "baseline",     "inicio": "${VENTANA_INICIO}", "fin": "${F1_FIN}",
      "esperado": "sin alertas" },
    { "nombre": "ruido",        "inicio": "${F2_INICIO}",      "fin": "${F2_FIN}",
      "inyeccion": "latencia 700ms en service-b",
      "esperado": "el umbral fijo dispara; la regla correlacionada no" },
    { "nombre": "incidente",    "inicio": "${F4_INICIO}",      "fin": "${F4_FIN}",
      "inyeccion": "postgres detenido",
      "esperado": "la regla correlacionada abre incidente con trace_id" },
    { "nombre": "recuperacion", "inicio": "${F4_FIN}",         "fin": "${VENTANA_FIN}",
      "esperado": "el incidente se cierra sin intervencion" }
  ]
}
JSON
ok "ventanas guardadas en ${RESULTADOS}/ventanas.json"

# Prometheus necesita un momento para consolidar el ultimo scrape.
sleep 20

python aiops/detector.py \
  --desde "${VENTANA_INICIO}" --hasta "${VENTANA_FIN}" \
  --comparar --json "${RESULTADOS}/deteccion.json"

echo
azul "Escenario completado"
echo "  Ventana analizada   ${VENTANA_INICIO}Z -> ${VENTANA_FIN}Z"
echo "  Resultados          ${RESULTADOS}/"
echo
