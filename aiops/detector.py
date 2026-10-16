#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Modulo B — Deteccion de anomalias y correlacion multi-senal.

El problema que resuelve no es "detectar picos": eso lo hace un umbral
estatico. El problema es que un umbral estatico tiene que elegir entre dos
fallos, y no puede evitar los dos a la vez:

    Umbral bajo   -> detecta todo, incluido el ruido normal del sistema.
                     El equipo recibe tantas alertas que deja de leerlas.
    Umbral alto   -> no hace ruido, pero se pierde las degradaciones que no
                     llegan al limite. El incidente se descubre por el cliente.

Este detector ataca el problema por otro lado, con dos ideas:

  1. BASELINE MOVIL. El limite no es un numero fijo sino lo que el sistema
     venia haciendo en la ventana anterior. Una latencia de 800 ms es normal
     bajo carga alta y anomala en reposo; un umbral fijo no distingue los dos
     casos, un baseline si.

  2. CORRELACION MULTI-SENAL. Una sola senal anomala no genera incidente.
     Hacen falta dos a la vez (errores Y latencia), sostenidas varios puntos
     seguidos. Un pico aislado de latencia es ruido; latencia alta sostenida
     acompanada de errores es un incidente.

Lo que sale no es una alerta por metrica, sino un INCIDENTE con las senales
que lo componen y el trace_id de un ejemplo real, para que quien lo reciba
abra la traza en vez de empezar a buscar.

Uso:

    # Contra el stack local (Prometheus en :9090)
    python aiops/detector.py --minutos 60

    # Comparando con los umbrales estaticos del dashboard
    python aiops/detector.py --minutos 60 --comparar

    # Sobre una ventana concreta (la de un experimento de caos)
    python aiops/detector.py --desde 2026-10-15T18:40:00 --hasta 2026-10-15T18:50:00
"""

import argparse
import json
import math
import os
import statistics
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

PROMETHEUS = os.environ.get("PROMETHEUS_URL", "http://localhost:9090")
JAEGER = os.environ.get("JAEGER_URL", "http://localhost:16686")

# ── Objetivos de nivel de servicio ──────────────────────────────────────────
# Son los mismos que ya usaba el dashboard del laboratorio anterior. Que el
# detector los lea de aqui y no los redefina es deliberado: si el SLO cambia,
# cambia en un sitio, y la alerta y el panel no pueden divergir.
SLO = {
    "disponibilidad_pct": 99.5,
    "latencia_p99_ms": 1000.0,
    "latencia_p95_ms": 500.0,
}

# ── Parametros de deteccion ─────────────────────────────────────────────────
PASO_S = 15               # resolucion de la serie
VENTANA_BASELINE = 20     # puntos de historia con los que se calcula el normal
SIGMAS = 2.0              # desviaciones sobre el baseline que marcan anomalia
DWELL = 3                 # puntos consecutivos anomalos antes de abrir incidente

# Separacion entre el punto evaluado y la historia con la que se compara.
#
# Es el parametro que mas cuesta descubrir y el que decide si el detector
# sirve. Sin el, la ventana movil acaba absorbiendo el propio incidente: en
# la ejecucion del escenario controlado, el baseline del p99 paso de 800 ms a
# 2.200 ms durante los tres minutos de caida, el limite subio con el, y el
# incidente dejo de parecer anomalo justo mientras estaba ocurriendo.
#
# Con 12 puntos (3 minutos) de separacion, los datos del incidente tardan ese
# tiempo en poder entrar en su propio baseline. Es el equivalente exacto del
# `offset 5m` de las subqueries de terraform/observabilidad/aiops.tf.
#
# El coste de este parametro es real y conviene nombrarlo: una degradacion que
# crezca mas despacio que la separacion se normaliza igualmente. Para eso esta
# la alerta de presupuesto de error, que mira horas en vez de minutos.
SEPARACION = 12

# Piso de sensibilidad. Sin el, un sistema en reposo (p99 estable en 50 ms,
# sigma de 2 ms) dispararia con cualquier variacion de 5 ms, que es ruido de
# medicion y no una degradacion. El baseline da la forma; este piso da la
# relevancia operativa.
PISO_RELEVANCIA = {
    "latencia_p99_ms": 50.0,   # ignora desviaciones de menos de 50 ms
    "error_rate_pct": 0.5,     # ignora desviaciones de menos de medio punto
}


# ════════════════════════════════════════════════════════════════════════════
# Acceso a Prometheus
# ════════════════════════════════════════════════════════════════════════════
def _consultar(ruta, parametros):
    url = PROMETHEUS.rstrip("/") + ruta + "?" + urllib.parse.urlencode(parametros)
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            carga = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:
        raise SystemExit(
            "No se pudo consultar Prometheus en %s\n  %s\n\n"
            "Levanta el stack con `docker compose up -d` o apunta a otro "
            "servidor con PROMETHEUS_URL." % (PROMETHEUS, exc)
        )

    if carga.get("status") != "success":
        raise SystemExit("Prometheus devolvio error: %s" % carga.get("error"))
    return carga["data"]


def serie(consulta, inicio, fin, paso=PASO_S):
    """Devuelve [(timestamp, valor)] para una consulta PromQL de rango."""
    datos = _consultar("/api/v1/query_range", {
        "query": consulta,
        "start": inicio.timestamp(),
        "end": fin.timestamp(),
        "step": paso,
    })

    if not datos["result"]:
        return []

    puntos = []
    for ts, valor in datos["result"][0]["values"]:
        try:
            v = float(valor)
        except (TypeError, ValueError):
            continue
        if math.isnan(v):
            continue
        puntos.append((float(ts), v))
    return puntos


def _trace_de_jaeger(inicio, fin, servicio="service-a"):
    """
    Pide al backend de trazas una traza CON ERROR dentro de la ventana.

    Es la via principal de enriquecimiento en este laboratorio, no la de
    reserva. El SDK de OpenTelemetry para Python 1.27 todavia no implementa
    exemplars (llegaron despues, y como experimentales), asi que la ruta
    metrica -> exemplar -> traza no existe aqui por mucho que el Collector
    exponga OpenMetrics y Prometheus tenga exemplar-storage activado.

    Preguntarle al backend de trazas da el mismo resultado y es mas robusto:
    no depende de que el exemplar caiga justo en el bucket correcto, y
    selecciona por "tiene error", que es mejor criterio que "fue lento".
    En GCP el equivalente es un filtro de Cloud Trace por status=ERROR sobre
    la misma ventana.
    """
    parametros = {
        "service": servicio,
        # Jaeger espera microsegundos.
        "start": int(inicio.timestamp() * 1_000_000),
        "end": int(fin.timestamp() * 1_000_000),
        # Jaeger devuelve las trazas MAS RECIENTES de la ventana, no una
        # muestra repartida. Con un limite bajo, un incidente de tres minutos
        # devuelve solo lo ocurrido en los ultimos segundos, que con suerte ya
        # es la recuperacion: exactamente el error que se cometio aqui con
        # limit=20, cuando la traza adjuntada venia de despues de que la base
        # de datos volviera.
        "limit": 200,
        "tags": json.dumps({"error": "true"}),
    }
    url = JAEGER.rstrip("/") + "/api/traces?" + urllib.parse.urlencode(parametros)

    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            datos = json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None

    # La seleccion importa mas de lo que parece, y este laboratorio lo
    # demostro dos veces:
    #
    #   Primer intento: coger la primera traza que devuelve el backend. Salio
    #   un error de DNS del borde de la ventana, no la caida de base de datos
    #   que habia provocado el incidente.
    #
    #   Segundo intento: coger la de span raiz mas largo. Salio una traza que
    #   habia devuelto 200 al cliente: el error estaba en un span interno que
    #   el fallback de service-a absorbio sin que nadie lo notara.
    #
    # El criterio correcto es el tercero: la traza debe haber FALLADO PARA EL
    # CLIENTE. Un error interno que el sistema absorbio no explica un
    # incidente; justo al reves, explica por que no lo hubo. Una alerta que
    # apunta al sitio equivocado es peor que una que no apunta a ninguno,
    # porque dirige la investigacion hacia una pista falsa.
    def raiz_fallo(spans):
        raiz = min(spans, key=lambda s: s.get("startTime", 0))
        etiquetas = {t.get("key"): t.get("value") for t in raiz.get("tags", [])}
        if etiquetas.get("otel.status_code") == "ERROR":
            return True, raiz
        try:
            return int(etiquetas.get("http.status_code", 0)) >= 500, raiz
        except (TypeError, ValueError):
            return False, raiz

    con_fallo, sin_fallo = [], []
    for traza in datos.get("data") or []:
        spans = traza.get("spans") or []
        if not spans:
            continue
        fallo, raiz = raiz_fallo(spans)
        (con_fallo if fallo else sin_fallo).append(
            (raiz.get("duration", 0), traza.get("traceID")))

    # Entre las que fallaron de cara al cliente, la mas lenta: es la que mejor
    # ilustra la degradacion. Si ninguna fallo de cara al cliente se devuelve
    # la mas lenta del resto, pero eso ya es una señal en si misma de que el
    # incidente no se parecia a lo que la alerta describe.
    candidatas = con_fallo or sin_fallo
    if not candidatas:
        return None
    return max(candidatas)[1]


def ejemplar_trace_id(consulta, inicio, fin):
    """
    Devuelve el trace_id de una peticion real afectada por el incidente.

    Es la pieza que convierte una alerta en algo accionable. Sin esto, quien
    recibe el aviso sabe que el p99 subio; con esto, tiene el identificador de
    una peticion concreta que lo sufrio y puede abrirla sin pasar antes por la
    fase de buscar un ejemplo.

    Se intentan dos vias, en este orden:
      1. Exemplars de Prometheus, que es el mecanismo estandar.
      2. El backend de trazas, que es el que funciona de verdad con el SDK
         de Python 1.27 (ver _trace_de_jaeger).
    """
    try:
        datos = _consultar("/api/v1/query_exemplars", {
            "query": consulta,
            "start": inicio.timestamp(),
            "end": fin.timestamp(),
        })
    except SystemExit:
        return _trace_de_jaeger(inicio, fin)

    mejor, mejor_valor = None, -1.0
    for grupo in datos or []:
        for ej in grupo.get("exemplars", []):
            etiquetas = ej.get("labels", {})
            tid = etiquetas.get("trace_id") or etiquetas.get("traceID")
            # Entre varios ejemplares se elige el de mayor latencia: es el que
            # mejor ilustra la degradacion que disparo el incidente.
            if tid and ej.get("value", 0) > mejor_valor:
                mejor, mejor_valor = tid, ej.get("value", 0)

    return mejor or _trace_de_jaeger(inicio, fin)


# ════════════════════════════════════════════════════════════════════════════
# Baseline y deteccion
# ════════════════════════════════════════════════════════════════════════════
def baseline_movil(valores, indice, ventana=VENTANA_BASELINE,
                   separacion=SEPARACION, robusto=False):
    """
    Calcula el comportamiento normal en el punto `indice` a partir de la
    historia anterior, dejando un hueco de `separacion` puntos entre ambos.

    El hueco es lo que impide que una degradacion sostenida se normalice sola.
    Sin el, el sistema aprende que estar roto es lo normal y deja de avisar
    justo cuando mas falta hace; con el, los datos del incidente tardan
    `separacion` puntos en poder influir en su propio limite.
    """
    fin = max(0, indice - separacion)
    historia = valores[max(0, fin - ventana):fin]
    if len(historia) < 5:
        return None, None

    if robusto:
        # Mediana y MAD. Resisten que la propia historia contenga parte del
        # incidente: un unico valor extremo desplaza la media, pero no la
        # mediana. El factor 1.4826 convierte MAD en una sigma equivalente
        # bajo distribucion normal.
        centro = statistics.median(historia)
        mad = statistics.median([abs(v - centro) for v in historia])
        dispersion = mad * 1.4826
    else:
        centro = statistics.fmean(historia)
        dispersion = statistics.pstdev(historia)

    return centro, dispersion


def detectar(puntos, nombre_metrica, sigmas=SIGMAS, robusto=False):
    """
    Marca cada punto como normal o anomalo contra su propio baseline.

    Devuelve [(ts, valor, centro, limite, es_anomalo)].
    """
    valores = [v for _, v in puntos]
    piso = PISO_RELEVANCIA.get(nombre_metrica, 0.0)
    salida = []

    for i, (ts, v) in enumerate(puntos):
        centro, dispersion = baseline_movil(valores, i, robusto=robusto)
        if centro is None:
            salida.append((ts, v, None, None, False))
            continue

        # El limite nunca queda por debajo de centro + piso: evita que un
        # sistema muy estable genere alertas por variaciones irrelevantes.
        limite = max(centro + sigmas * dispersion, centro + piso)
        salida.append((ts, v, centro, limite, v > limite))

    return salida


def rachas(serie_detectada, dwell=DWELL):
    """
    Agrupa puntos anomalos consecutivos y descarta las rachas mas cortas que
    `dwell`.

    Esta es la mitad del filtrado de ruido. Un pico de un solo punto puede ser
    un GC, un arranque en frio o una reprogramacion de Pod: cosas que se
    arreglan solas antes de que nadie llegue al teclado. Exigir persistencia
    separa la degradacion del hipo.
    """
    bloques, actual = [], []
    for punto in serie_detectada:
        if punto[4]:
            actual.append(punto)
        else:
            if len(actual) >= dwell:
                bloques.append(actual)
            actual = []
    if len(actual) >= dwell:
        bloques.append(actual)
    return bloques


def solapan(a, b, tolerancia_s=60):
    """¿Dos rachas se refieren al mismo momento?"""
    ini_a, fin_a = a[0][0], a[-1][0]
    ini_b, fin_b = b[0][0], b[-1][0]
    return ini_a - tolerancia_s <= fin_b and ini_b - tolerancia_s <= fin_a


# ════════════════════════════════════════════════════════════════════════════
# Reglas
# ════════════════════════════════════════════════════════════════════════════
CONSULTAS = {
    "latencia_p99_ms": (
        '1000 * histogram_quantile(0.99, sum by (le) ('
        'rate(http_request_duration_seconds_bucket{source="collector",service="service-a"}[1m])))'
    ),
    # El `or vector(0)` del numerador no es cosmetico. Sin el, mientras no haya
    # ni un solo 5xx la etiqueta status="5xx" no existe, sum() no devuelve
    # ninguna serie y TODA la expresion queda vacia. El resultado es que la
    # serie de errores solo tiene puntos DURANTE el incidente, asi que no hay
    # historia previa con la que construir un baseline y la anomalia nunca se
    # detecta: justo al reves de lo que se quiere.
    "error_rate_pct": (
        '100 * ((sum(rate(http_requests_total{source="collector",service="service-a",status="5xx"}[1m])) or vector(0)) '
        '/ clamp_min(sum(rate(http_requests_total{source="collector",service="service-a"}[1m])), 0.001))'
    ),
    "throughput_rps": (
        'sum(rate(http_requests_total{source="collector",service="service-a"}[1m]))'
    ),
}


def regla_correlacionada(inicio, fin, robusto=False):
    """
    La regla del enunciado: error_rate por encima de su baseline + 2 sigma Y
    latencia p99 por encima del SLO, a la vez.

    El operador es Y, no O, y esa eleccion es todo el valor de la regla:

      Solo latencia alta  -> el sistema esta lento pero responde. Puede ser un
                             pico de trafico legitimo. No se despierta a nadie.
      Solo errores        -> unos pocos 5xx sin impacto en latencia suelen ser
                             una dependencia opcional degradada, no una caida.
      Las dos juntas      -> el sistema esta devolviendo errores Y tardando en
                             hacerlo. Eso es un incidente real.
    """
    series = {k: serie(q, inicio, fin) for k, q in CONSULTAS.items()}

    if not series["latencia_p99_ms"]:
        raise SystemExit(
            "No hay datos de latencia en la ventana pedida.\n"
            "Comprueba que el stack lleva corriendo con trafico el tiempo "
            "suficiente, o amplia --minutos."
        )

    det_lat = detectar(series["latencia_p99_ms"], "latencia_p99_ms", robusto=robusto)
    det_err = detectar(series["error_rate_pct"], "error_rate_pct", robusto=robusto)

    rachas_lat = rachas(det_lat)
    rachas_err = rachas(det_err)

    incidentes = []
    for rl in rachas_lat:
        # Segunda condicion del enunciado: ademas de ser anomala contra su
        # propio baseline, la latencia debe violar el SLO. Una subida del 300 %
        # sobre un baseline de 20 ms sigue estando dentro del objetivo y no
        # justifica despertar a nadie.
        pico = max(p[1] for p in rl)
        if pico < SLO["latencia_p99_ms"]:
            continue

        acompanantes = [re_ for re_ in rachas_err if solapan(rl, re_)]
        if not acompanantes:
            continue

        t_ini = datetime.fromtimestamp(rl[0][0], tz=timezone.utc)
        t_fin = datetime.fromtimestamp(rl[-1][0], tz=timezone.utc)
        # Sin margen alrededor de la ventana: ampliarla hacia fuera trae
        # trazas de antes o de despues del fallo, que es justo lo que no se
        # quiere adjuntar a un incidente.
        trace = ejemplar_trace_id(
            'http_request_duration_seconds_bucket{source="collector",service="service-a"}',
            t_ini, t_fin,
        )

        err_pico = max(p[1] for r in acompanantes for p in r)

        incidentes.append({
            "inicio": t_ini.isoformat(),
            "fin": t_fin.isoformat(),
            "duracion_s": round(rl[-1][0] - rl[0][0], 1),
            "latencia_p99_pico_ms": round(pico, 1),
            "latencia_p99_baseline_ms": round(rl[0][2], 1) if rl[0][2] else None,
            "error_rate_pico_pct": round(err_pico, 2),
            "error_rate_baseline_pct": round(acompanantes[0][0][2], 2)
                                        if acompanantes[0][0][2] is not None else None,
            "senales": ["latencia_p99", "error_rate"],
            "trace_id": trace,
            "severidad": "critica" if pico > 2 * SLO["latencia_p99_ms"] else "alta",
        })

    return incidentes, det_lat, det_err, rachas_lat, rachas_err


# ════════════════════════════════════════════════════════════════════════════
# Comparacion contra umbrales estaticos
# ════════════════════════════════════════════════════════════════════════════
def comparar_con_estatico(det_lat, det_err, incidentes):
    """
    Cuenta cuantas alertas habria emitido cada enfoque sobre los mismos datos.

    Las dos configuraciones estaticas son las que un equipo elegiria de forma
    natural, y cada una falla de una manera distinta:

      estricto  p99 > 500 ms   -> el valor del SLO de p95, un error comun.
                                  Detecta todo, incluido el ruido.
      laxo      p99 > 2000 ms  -> el que se acaba poniendo tras varias noches
                                  de alertas falsas. Silencioso y ciego.

    La metrica que importa no es cuantas alertas emite cada uno, sino cuantas
    VECES SE INTERRUMPE a una persona para contarle algo que ya sabia o que no
    requeria accion.
    """
    def alertas_estaticas(serie_detectada, umbral):
        bloques, actual = [], []
        for ts, v, _, _, _ in serie_detectada:
            if v > umbral:
                actual.append((ts, v, None, None, True))
            else:
                if actual:
                    bloques.append(actual)
                actual = []
        if actual:
            bloques.append(actual)
        return bloques

    estricto = alertas_estaticas(det_lat, 500.0)
    laxo = alertas_estaticas(det_lat, 2000.0)

    # Un bloque estatico cuenta como "util" si coincide con un incidente que
    # la regla correlacionada tambien abrio; si no, es una interrupcion que no
    # llevaba a ninguna accion.
    def clasificar(bloques):
        utiles = 0
        for b in bloques:
            ini = datetime.fromtimestamp(b[0][0], tz=timezone.utc).isoformat()
            fin = datetime.fromtimestamp(b[-1][0], tz=timezone.utc).isoformat()
            if any(inc["inicio"] <= fin and ini <= inc["fin"] for inc in incidentes):
                utiles += 1
        return utiles, len(bloques) - utiles

    est_utiles, est_ruido = clasificar(estricto)
    lax_utiles, lax_ruido = clasificar(laxo)

    total_estricto = len(estricto)
    reduccion = (
        100.0 * (total_estricto - len(incidentes)) / total_estricto
        if total_estricto else 0.0
    )

    return {
        "umbral_estricto_500ms": {
            "alertas": total_estricto,
            "coinciden_con_incidente": est_utiles,
            "sin_accion_asociada": est_ruido,
        },
        "umbral_laxo_2000ms": {
            "alertas": len(laxo),
            "coinciden_con_incidente": lax_utiles,
            "sin_accion_asociada": lax_ruido,
            "incidentes_no_detectados": max(0, len(incidentes) - lax_utiles),
        },
        "regla_correlacionada": {
            "incidentes": len(incidentes),
            "con_trace_id": sum(1 for i in incidentes if i.get("trace_id")),
        },
        "reduccion_de_ruido_pct": round(reduccion, 1),
    }


# ════════════════════════════════════════════════════════════════════════════
# Salida
# ════════════════════════════════════════════════════════════════════════════
AZUL, VERDE, AMARILLO, ROJO, GRIS, FIN = (
    "\033[1;34m", "\033[1;32m", "\033[1;33m", "\033[1;31m", "\033[0;90m", "\033[0m"
)


def imprimir(incidentes, comparacion, det_lat, inicio, fin):
    print()
    print(AZUL + "═" * 74 + FIN)
    print(AZUL + "  Modulo B — Deteccion de anomalias y correlacion multi-senal" + FIN)
    print(AZUL + "═" * 74 + FIN)
    print()
    print("  Ventana      %s  ->  %s" % (
        inicio.strftime("%Y-%m-%d %H:%M:%S"), fin.strftime("%H:%M:%S")))
    print("  Puntos       %d (paso %ds)" % (len(det_lat), PASO_S))
    print("  Baseline     media movil de %d puntos, %s sigma" % (VENTANA_BASELINE, SIGMAS))
    print("  Separacion   %d puntos (%ds) entre el punto y su historia" % (
        SEPARACION, SEPARACION * PASO_S))
    print("  Persistencia %d puntos consecutivos (%ds)" % (DWELL, DWELL * PASO_S))
    print()

    if not incidentes:
        print(VERDE + "  Sin incidentes correlacionados en la ventana." + FIN)
        print(GRIS + "  El sistema estuvo dentro de su comportamiento normal, o la" + FIN)
        print(GRIS + "  degradacion no cumplio las dos condiciones a la vez." + FIN)
    else:
        print(ROJO + "  %d incidente(s) correlacionado(s)" % len(incidentes) + FIN)
        print()
        for n, inc in enumerate(incidentes, 1):
            color = ROJO if inc["severidad"] == "critica" else AMARILLO
            print(color + "  ── Incidente %d · %s ──" % (n, inc["severidad"].upper()) + FIN)
            print("     Inicio        %s" % inc["inicio"])
            print("     Duracion      %.0f s" % inc["duracion_s"])
            print("     p99           %.0f ms  (normal: %s ms · SLO: %.0f ms)" % (
                inc["latencia_p99_pico_ms"],
                inc["latencia_p99_baseline_ms"], SLO["latencia_p99_ms"]))
            print("     error_rate    %.2f %%  (normal: %s %%)" % (
                inc["error_rate_pico_pct"], inc["error_rate_baseline_pct"]))
            if inc["trace_id"]:
                print(VERDE + "     trace_id      %s" % inc["trace_id"] + FIN)
                print(GRIS + "                   %s/trace/%s" % (JAEGER, inc["trace_id"]) + FIN)
            else:
                print(GRIS + "     trace_id      sin exemplar en la ventana" + FIN)
            print()

    if comparacion:
        print(AZUL + "  ── Comparacion con umbrales estaticos " + "─" * 35 + FIN)
        print()
        e = comparacion["umbral_estricto_500ms"]
        l = comparacion["umbral_laxo_2000ms"]
        c = comparacion["regla_correlacionada"]

        print("     %-28s %8s %10s %12s" % ("enfoque", "alertas", "utiles", "sin accion"))
        print("     " + "─" * 62)
        print("     %-28s %8d %10d %12d" % (
            "umbral fijo p99 > 500 ms", e["alertas"],
            e["coinciden_con_incidente"], e["sin_accion_asociada"]))
        print("     %-28s %8d %10d %12d" % (
            "umbral fijo p99 > 2000 ms", l["alertas"],
            l["coinciden_con_incidente"], l["sin_accion_asociada"]))
        print(VERDE + "     %-28s %8d %10d %12d" % (
            "baseline + correlacion", c["incidentes"], c["incidentes"], 0) + FIN)
        print()

        if l["incidentes_no_detectados"]:
            print(ROJO + "     El umbral laxo se perdio %d incidente(s)." %
                  l["incidentes_no_detectados"] + FIN)
        print("     Reduccion de ruido frente al umbral estricto: " +
              VERDE + "%.1f %%" % comparacion["reduccion_de_ruido_pct"] + FIN)
        print("     Incidentes con trace_id adjunto: %d de %d" % (
            c["con_trace_id"], c["incidentes"]))
        print()


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--minutos", type=int, default=60,
                   help="ventana hacia atras desde ahora (por defecto 60)")
    p.add_argument("--desde", help="inicio ISO, p. ej. 2026-10-15T18:40:00")
    p.add_argument("--hasta", help="fin ISO")
    p.add_argument("--comparar", action="store_true",
                   help="compara contra umbrales estaticos")
    p.add_argument("--robusto", action="store_true",
                   help="usa mediana y MAD en vez de media y sigma")
    p.add_argument("--json", dest="ruta_json",
                   help="guarda el resultado en un archivo JSON")
    args = p.parse_args()

    if args.desde:
        inicio = datetime.fromisoformat(args.desde).replace(tzinfo=timezone.utc)
        fin = (datetime.fromisoformat(args.hasta).replace(tzinfo=timezone.utc)
               if args.hasta else datetime.now(timezone.utc))
    else:
        fin = datetime.now(timezone.utc)
        inicio = fin - timedelta(minutes=args.minutos)

    incidentes, det_lat, det_err, _, _ = regla_correlacionada(
        inicio, fin, robusto=args.robusto)

    comparacion = comparar_con_estatico(det_lat, det_err, incidentes) \
        if args.comparar else None

    imprimir(incidentes, comparacion, det_lat, inicio, fin)

    if args.ruta_json:
        salida = {
            "generado": datetime.now(timezone.utc).isoformat(),
            "ventana": {"inicio": inicio.isoformat(), "fin": fin.isoformat()},
            "parametros": {
                "ventana_baseline": VENTANA_BASELINE,
                "sigmas": SIGMAS,
                "dwell": DWELL,
                "separacion": SEPARACION,
                "paso_s": PASO_S,
                "robusto": args.robusto,
                "slo": SLO,
            },
            "incidentes": incidentes,
            "comparacion": comparacion,
        }
        os.makedirs(os.path.dirname(os.path.abspath(args.ruta_json)), exist_ok=True)
        with open(args.ruta_json, "w", encoding="utf-8") as fh:
            json.dump(salida, fh, indent=2, ensure_ascii=False)
        print("  Resultado guardado en %s\n" % args.ruta_json)

    # Codigo de salida util en CI: 1 si hay incidentes abiertos.
    return 1 if incidentes else 0


if __name__ == "__main__":
    sys.exit(main())
