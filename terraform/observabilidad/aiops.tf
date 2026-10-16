# ════════════════════════════════════════════════════════════════════════════
# Modulo B — Deteccion de anomalias y correlacion multi-senal
#
# Tres politicas que se despliegan JUNTAS a proposito, porque el objetivo del
# modulo no es tener una alerta sino poder comparar tres formas de alertar
# sobre los mismos datos:
#
#   1. umbral_estatico_estricto   el punto de partida de cualquier equipo
#   2. umbral_estatico_laxo       lo que queda tras varias noches de ruido
#   3. correlacion_multisenal     baseline movil + dos senales + persistencia
#
# Las dos primeras se marcan con severidad informativa y NO notifican: existen
# para poder contar cuantas veces habrian despertado a alguien. Solo la
# tercera lleva canal de notificacion.
#
# La implementacion usa PromQL sobre Managed Prometheus en vez de las
# condiciones nativas de Cloud Monitoring porque el baseline movil se expresa
# en una sola consulta con subqueries; con el modelo de condiciones nativo
# haria falta una metrica derivada aparte, y la definicion del baseline
# quedaria separada de la alerta que la usa.
# ════════════════════════════════════════════════════════════════════════════

locals {
  # Tasa de error de service-a, en porcentaje. clamp_min evita la division por
  # cero cuando no hay trafico: sin el, una ventana sin peticiones produce NaN
  # y la alerta entra en estado desconocido en lugar de en estado sano.
  promql_error_rate = <<-EOT
    100 * sum(rate(http_requests_total{service="service-a",status="5xx"}[5m]))
        / clamp_min(sum(rate(http_requests_total{service="service-a"}[5m])), 0.001)
  EOT

  # p99 en segundos.
  promql_p99 = <<-EOT
    histogram_quantile(0.99,
      sum by (le) (rate(http_request_duration_seconds_bucket{service="service-a"}[5m])))
  EOT
}

# ════════════════════════════════════════════════════════════════════════════
# 1. Umbral estatico estricto — la referencia "ruidosa"
# ════════════════════════════════════════════════════════════════════════════
resource "google_monitoring_alert_policy" "umbral_estricto" {
  display_name = "[referencia] p99 > 500 ms — umbral fijo estricto"
  combiner     = "OR"
  enabled      = var.desplegar_referencias

  documentation {
    subject   = "Referencia de comparacion, no accionar"
    content   = <<-EOT
      Esta politica NO notifica. Existe para medir cuantas veces habria
      interrumpido a una persona un umbral fijo de 500 ms sobre el p99.

      500 ms es el SLO de p95, no el de p99. Ponerlo sobre el p99 es un error
      frecuente, y el que produce la mayor parte del ruido de guardia: el p99
      recoge por definicion la cola de la distribucion, asi que supera ese
      valor en situaciones perfectamente normales (un arranque en frio, un
      GC, una reprogramacion de Pod).
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "p99 por encima de 500 ms"

    condition_prometheus_query_language {
      query               = "${chomp(local.promql_p99)} > 0.5"
      duration            = "60s"
      evaluation_interval = "60s"
    }
  }

  severity = "WARNING"

  alert_strategy {
    auto_close = "1800s"
  }

  depends_on = [google_project_service.requeridas]
}

# ════════════════════════════════════════════════════════════════════════════
# 2. Umbral estatico laxo — la referencia "ciega"
# ════════════════════════════════════════════════════════════════════════════
resource "google_monitoring_alert_policy" "umbral_laxo" {
  display_name = "[referencia] p99 > 2000 ms — umbral fijo laxo"
  combiner     = "OR"
  enabled      = var.desplegar_referencias

  documentation {
    subject   = "Referencia de comparacion, no accionar"
    content   = <<-EOT
      Esta politica NO notifica. Es el umbral al que se acaba llegando despues
      de subir el limite varias veces para silenciar el ruido de la politica
      anterior.

      El resultado de ese ajuste es predecible: el sistema deja de avisar casi
      siempre, incluso cuando hay degradaciones reales que no llegan a los dos
      segundos. El equipo cree que tiene alertas; lo que tiene es silencio.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "p99 por encima de 2000 ms"

    condition_prometheus_query_language {
      query               = "${chomp(local.promql_p99)} > 2"
      duration            = "60s"
      evaluation_interval = "60s"
    }
  }

  severity = "WARNING"

  alert_strategy {
    auto_close = "1800s"
  }

  depends_on = [google_project_service.requeridas]
}

# ════════════════════════════════════════════════════════════════════════════
# 3. Correlacion multi-senal — la politica que SI notifica
# ════════════════════════════════════════════════════════════════════════════
resource "google_monitoring_alert_policy" "correlacion_multisenal" {
  display_name = "Incidente correlacionado — errores anomalos Y latencia sobre SLO"
  combiner     = "OR"

  documentation {
    subject   = "Incidente en service-a: errores por encima del baseline y p99 sobre el SLO"
    content   = <<-EOT
      ## Que ha pasado

      Dos senales independientes se han degradado a la vez durante al menos
      tres minutos:

      1. La **tasa de error** supera su propio baseline de la ultima hora mas
         dos desviaciones tipicas. No es un umbral fijo: el limite se recalcula
         con lo que el sistema venia haciendo.
      2. El **p99 de latencia** supera el SLO de 1000 ms.

      El operador es **Y**, y ahi esta todo el valor de la regla:

      - Solo latencia alta: el sistema esta lento pero responde. Puede ser un
        pico de trafico legitimo. No se despierta a nadie.
      - Solo errores: unos pocos 5xx sin impacto en latencia suelen ser una
        dependencia opcional degradada, no una caida.
      - Las dos a la vez: el sistema devuelve errores **y** tarda en hacerlo.
        Eso es un incidente.

      ## Primer paso

      Abre una traza del periodo afectado. El filtro ya viene puesto:

      [Trazas con error en la ventana del incidente](https://console.cloud.google.com/traces/list?project=${var.project_id}&tid=&pageState=%5B%7B%22filters%22:%5B%7B%22k%22:%22%2Bstatus%22,%22v%22:%22ERROR%22%7D%5D%7D%5D)

      La causa suele estar en el primer span con estado ERROR de la cadena, no
      en el ultimo: `service-a` degrada con elegancia ante fallos de
      `service-b` y de `data-service`, asi que si el error llega al cliente, lo
      mas probable es que venga de la dependencia critica (la base de datos).

      ## Causas vistas en el laboratorio

      | Sintoma adicional | Causa probable |
      |---|---|
      | `db_errors_total` sube a la vez | Base de datos inalcanzable |
      | `response_flags` = UO en la malla | Circuit breaker abierto hacia service-b |
      | CPU del contenedor en el limite | Agotamiento de recursos (ver E2) |
      | `chaos.injected` = true en los spans | Es un experimento en curso, no un incidente |

      La ultima fila importa: `data-service` marca sus fallos deliberados en el
      span. Antes de escalar, comprueba que no hay un Game Day corriendo.
    EOT
    mime_type = "text/markdown"
  }

  # UNA sola condicion, no dos.
  #
  # Cloud Monitoring no admite varias condiciones PromQL en la misma politica:
  #   "Alert policies with prometheus_query_language condition type can only
  #    have a single condition"
  #
  # La correlacion se expresa entonces dentro de la propia consulta, con el
  # operador `and` de PromQL: devuelve la serie izquierda solo donde la derecha
  # tambien existe. El resultado es identico y de hecho mas fiel a la
  # intencion, porque no son dos alertas que coinciden en el tiempo sino una
  # unica condicion compuesta.
  conditions {
    display_name = "error_rate sobre baseline + 2 sigma Y p99 sobre el SLO"

    condition_prometheus_query_language {
      query = <<-PROMQL
        (
          (${chomp(local.promql_error_rate)})
          >
          (
            avg_over_time((${chomp(local.promql_error_rate)})[1h:5m] offset 5m)
            + 2 * stddev_over_time((${chomp(local.promql_error_rate)})[1h:5m] offset 5m)
            + 0.5
          )
        )
        and
        (
          (${chomp(local.promql_p99)}) > ${var.slo_p99_ms / 1000}
        )
      PROMQL

      # Tres minutos de persistencia, el equivalente del parametro `dwell` de
      # aiops/detector.py: un pico de un solo punto puede ser un GC o un
      # arranque en frio, cosas que se arreglan solas antes de que nadie
      # llegue al teclado.
      duration            = "180s"
      evaluation_interval = "60s"
    }
  }

  severity = "CRITICAL"

  notification_channels = [google_monitoring_notification_channel.correo.id]

  alert_strategy {
    auto_close = "3600s"

    # Sin `notification_rate_limit`: Cloud Monitoring solo lo admite en
    # politicas basadas en logs.
    #   "only log-based alert policies may specify a notification rate limit"
    # El control de repeticion queda en manos de `auto_close`, que cierra el
    # incidente tras una hora sin que la condicion se cumpla.
  }

  depends_on = [google_project_service.requeridas]
}

# ════════════════════════════════════════════════════════════════════════════
# 4. Consumo del presupuesto de error
#
# Complementa a la anterior en otra escala de tiempo. La correlacion detecta
# el incidente agudo; esto detecta la degradacion lenta que nunca dispara
# ninguna alerta puntual pero se come el margen del trimestre.
#
# Con un SLO de disponibilidad del 99,5 % el presupuesto es del 0,5 %. Una
# tasa de consumo de 14,4 agota un presupuesto mensual en dos dias: es el
# valor que recomienda el SRE Workbook para la alerta de quemado rapido.
# ════════════════════════════════════════════════════════════════════════════
resource "google_monitoring_alert_policy" "presupuesto_error" {
  display_name = "Presupuesto de error — consumo acelerado"
  combiner     = "OR"

  documentation {
    subject   = "El presupuesto de error se esta consumiendo mas rapido de lo sostenible"
    content   = <<-EOT
      La tasa de error de la ultima hora consume el presupuesto mensual
      ${var.factor_quemado} veces mas rapido de lo sostenible.

      Esto NO es una caida: puede que ningun usuario se haya quejado y que
      ninguna alerta puntual haya saltado. Es una degradacion lenta, y es
      precisamente el tipo de problema que el alertado por umbrales no ve.

      **Decision a tomar**: con el presupuesto en riesgo, lo correcto es
      congelar los despliegues de funcionalidad nueva y dedicar el esfuerzo a
      fiabilidad hasta que la tasa vuelva a su nivel sostenible.

      SLO de disponibilidad: ${var.slo_disponibilidad_pct} %
      Presupuesto de error:  ${format("%.2f", 100 - var.slo_disponibilidad_pct)} %
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Consumo ${var.factor_quemado}x sobre lo sostenible"

    condition_prometheus_query_language {
      query = <<-PROMQL
        (
          sum(rate(http_requests_total{service="service-a",status="5xx"}[1h]))
          / clamp_min(sum(rate(http_requests_total{service="service-a"}[1h])), 0.001)
        ) > ${var.factor_quemado} * ${(100 - var.slo_disponibilidad_pct) / 100}
      PROMQL

      duration            = "300s"
      evaluation_interval = "120s"
    }
  }

  severity = "WARNING"

  notification_channels = [google_monitoring_notification_channel.correo.id]

  alert_strategy {
    auto_close = "7200s"
  }

  depends_on = [google_project_service.requeridas]
}

# ════════════════════════════════════════════════════════════════════════════
# 5. Ausencia de senal
#
# La unica alerta que no mide una degradacion sino un silencio. Nace de un
# hallazgo concreto del laboratorio: al pausar el contenedor de PostgreSQL,
# las peticiones se quedaron colgadas indefinidamente y NO se registro ni un
# error ni una latencia, porque el bloque que publica las metricas nunca
# llego a ejecutarse.
#
# Un sistema que no responde tampoco emite senales. Sin esta politica, el
# incidente mas grave posible es el unico que pasa desapercibido.
# ════════════════════════════════════════════════════════════════════════════
resource "google_monitoring_alert_policy" "ausencia_de_senal" {
  display_name = "Ausencia de senal — service-a dejo de reportar"
  combiner     = "OR"

  documentation {
    subject   = "No llegan metricas de service-a"
    content   = <<-EOT
      Durante los ultimos cinco minutos no ha llegado ninguna metrica de
      peticiones de `service-a`.

      Las dos causas posibles son muy distintas y hay que distinguirlas antes
      de actuar:

      1. **No hay trafico.** Normal fuera de horario o en un entorno de
         pruebas. Comprueba el trafico de entrada en el balanceador.
      2. **El servicio esta colgado.** Es el caso grave: un proceso bloqueado
         esperando a una dependencia que no responde sigue aceptando
         conexiones, pero no termina ninguna peticion, asi que nunca publica
         la metrica. Se observo exactamente esto al pausar la base de datos
         durante el Modulo B.

      Para distinguirlas: si `up` del exportador sigue a 1 pero el contador de
      peticiones no avanza, es el segundo caso.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Sin metricas de peticiones durante 5 min"

    condition_prometheus_query_language {
      query               = "absent(sum(rate(http_requests_total{service=\"service-a\"}[5m])))"
      duration            = "300s"
      evaluation_interval = "60s"
    }
  }

  severity = "CRITICAL"

  notification_channels = [google_monitoring_notification_channel.correo.id]

  alert_strategy {
    auto_close = "1800s"
  }

  depends_on = [google_project_service.requeridas]
}
