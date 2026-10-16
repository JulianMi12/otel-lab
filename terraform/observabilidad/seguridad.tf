# ════════════════════════════════════════════════════════════════════════════
# Modulo C — Observabilidad de red y seguridad en GCP
#
# La idea que organiza este archivo: las cuatro senales doradas de Google
# (latencia, trafico, errores, saturacion) describen la SALUD de un sistema,
# pero no dicen nada sobre si alguien lo esta atacando. Un sistema bajo
# intrusion puede tener las cuatro en verde.
#
# Lo que sigue define el equivalente para seguridad, con la misma disciplina:
# pocas senales, cada una con una pregunta concreta detras.
#
#   Autorizacion  ¿A quien se le esta negando el paso?
#   Administracion ¿Quien cambia la configuracion de la plataforma?
#   Reconocimiento ¿Alguien esta probando rutas que no existen?
#   Exfiltracion  ¿Esta saliendo mas informacion de la habitual?
#
# POR QUE SOBRE CLOUD RUN Y NO SOBRE LA MALLA
#
#   La primera version de este archivo media sobre `k8s_container` y
#   `gce_subnetwork`: logs de acceso de los sidecars de Istio y VPC Flow Logs
#   del cluster. Es la version correcta cuando el cluster existe.
#
#   Pero el despliegue permanente de este laboratorio es Cloud Run, que no
#   tiene ni sidecars ni subred propia. Aplicar aquella version habria creado
#   cuatro metricas y un panel que nunca recibirian un solo dato: un tablero
#   vacio que parece funcionar hasta que alguien lo mira de cerca, que es
#   justo el tipo de observabilidad que este laboratorio critica.
#
#   Las metricas de abajo miden las mismas cuatro preguntas sobre las senales
#   que Cloud Run SI produce. Las de la malla siguen disponibles detras de
#   `desplegar_metricas_malla`, para cuando el cluster este levantado.
# ════════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════════
# Metricas derivadas de logs
# ════════════════════════════════════════════════════════════════════════════

# ── 1. Autorizacion denegada ────────────────────────────────────────────────
# Cloud Run devuelve 403 cuando IAM rechaza la invocacion. En este despliegue
# los servicios internos solo aceptan a la cuenta de servicio del orquestador,
# asi que un 403 significa que alguien -o algo- intento invocarlos sin la
# identidad correcta.
#
# No es teorico: durante el despliegue, la propagacion de los permisos de IAM
# tardo unos minutos y las llamadas internas devolvieron 403 mientras tanto.
# Esta metrica los capturo.
resource "google_logging_metric" "autorizacion_denegada" {
  name   = "seguridad/autorizacion_denegada"
  filter = <<-EOT
    resource.type="cloud_run_revision"
    httpRequest.status=403
  EOT

  description = "Invocaciones rechazadas por IAM"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "servicio"
      value_type  = "STRING"
      description = "Servicio que rechazo la llamada"
    }
  }

  label_extractors = {
    "servicio" = "EXTRACT(resource.labels.service_name)"
  }

  depends_on = [google_project_service.requeridas]
}

# ── 2. Actividad administrativa ─────────────────────────────────────────────
# Los Cloud Audit Logs registran quien cambia la configuracion del proyecto.
# Es la senal que responde a "¿quien toco esto?" despues de un incidente, y
# la unica que no se puede reconstruir a posteriori si no se estaba recogiendo.
resource "google_logging_metric" "actividad_administrativa" {
  name   = "seguridad/actividad_administrativa"
  filter = <<-EOT
    logName:"cloudaudit.googleapis.com%2Factivity"
    protoPayload.methodName!="google.logging.v2.ConfigServiceV2.CreateLogMetric"
  EOT

  description = "Cambios de configuracion sobre el proyecto, por identidad"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "identidad"
      value_type  = "STRING"
      description = "Quien realizo el cambio"
    }

    labels {
      key         = "metodo"
      value_type  = "STRING"
      description = "Operacion ejecutada"
    }
  }

  label_extractors = {
    "identidad" = "EXTRACT(protoPayload.authenticationInfo.principalEmail)"
    "metodo"    = "EXTRACT(protoPayload.methodName)"
  }

  depends_on = [google_project_service.requeridas]
}

# ── 3. Reconocimiento ───────────────────────────────────────────────────────
# Peticiones a rutas que no existen. Una aplicacion con clientes legitimos
# produce muy pocas: los clientes conocen sus endpoints. Un volumen alto de
# 404 es el patron clasico de alguien probando rutas a ver que encuentra
# (/admin, /.env, /wp-login.php).
resource "google_logging_metric" "reconocimiento" {
  name   = "seguridad/reconocimiento"
  filter = <<-EOT
    resource.type="cloud_run_revision"
    httpRequest.status=404
  EOT

  description = "Peticiones a rutas inexistentes"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "ruta"
      value_type  = "STRING"
      description = "Ruta solicitada"
    }
  }

  label_extractors = {
    "ruta" = "EXTRACT(httpRequest.requestUrl)"
  }

  depends_on = [google_project_service.requeridas]
}

# ── 4. Volumen de salida ────────────────────────────────────────────────────
# Bytes devueltos al cliente. Es el equivalente funcional del analisis de
# exfiltracion sobre Flow Logs: lo que importa no es el trafico de red en
# bruto sino cuanta informacion sale hacia fuera.
#
# El valor de la metrica son los BYTES, no el numero de peticiones: una
# exfiltracion son pocas peticiones con mucho volumen, y contando peticiones
# pasaria desapercibida.
resource "google_logging_metric" "salida_bytes" {
  name   = "seguridad/salida_bytes"
  filter = <<-EOT
    resource.type="cloud_run_revision"
    httpRequest.responseSize>0
  EOT

  description = "Bytes devueltos a clientes externos"

  # DISTRIBUTION y no INT64: Cloud Monitoring solo admite `value_extractor`
  # sobre metricas de distribucion.
  #
  # La restriccion acaba siendo una mejora. Una distribucion permite preguntar
  # algo mas fino que el volumen total: cual fue la respuesta MAS GRANDE. Y
  # una exfiltracion es exactamente eso -pocas peticiones devolviendo mucho-,
  # no un aumento suave del trafico agregado.
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "By"

    labels {
      key         = "servicio"
      value_type  = "STRING"
      description = "Servicio que respondio"
    }
  }

  bucket_options {
    exponential_buckets {
      num_finite_buckets = 16
      growth_factor      = 4
      scale              = 100
    }
  }

  value_extractor = "EXTRACT(httpRequest.responseSize)"

  label_extractors = {
    "servicio" = "EXTRACT(resource.labels.service_name)"
  }

  depends_on = [google_project_service.requeridas]
}

# ════════════════════════════════════════════════════════════════════════════
# Metricas de la malla
#
# Solo tienen sentido con el cluster levantado: miden los logs de acceso L7
# que emiten los sidecars de Envoy. Desactivadas por defecto para no dejar
# metricas sin datos en un proyecto donde el cluster no existe.
# ════════════════════════════════════════════════════════════════════════════
resource "google_logging_metric" "malla_autorizacion_denegada" {
  count = var.desplegar_metricas_malla ? 1 : 0

  name   = "seguridad/malla_autorizacion_denegada"
  filter = <<-EOT
    resource.type="k8s_container"
    jsonPayload.codigo="403"
  EOT

  description = "Peticiones rechazadas por una AuthorizationPolicy de Istio"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "origen"
      value_type  = "STRING"
      description = "Identidad SPIFFE del llamante rechazado"
    }
  }

  label_extractors = {
    "origen" = "EXTRACT(jsonPayload.origen)"
  }

  depends_on = [google_project_service.requeridas]
}

resource "google_logging_metric" "malla_sin_mtls" {
  count = var.desplegar_metricas_malla ? 1 : 0

  name   = "seguridad/malla_trafico_sin_mtls"
  filter = <<-EOT
    resource.type="k8s_container"
    jsonPayload.origen=""
    jsonPayload.codigo!=""
  EOT

  description = "Peticiones L7 sin identidad mTLS en el llamante"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_service.requeridas]
}

# ════════════════════════════════════════════════════════════════════════════
# Alertas de seguridad
# ════════════════════════════════════════════════════════════════════════════

resource "google_monitoring_alert_policy" "autorizacion_denegada" {
  display_name = "Seguridad — invocaciones rechazadas por IAM"
  combiner     = "OR"

  documentation {
    subject   = "Varias invocaciones rechazadas por falta de autorizacion"
    content   = <<-EOT
      Se han rechazado mas de diez invocaciones en cinco minutos por falta de
      autorizacion (403).

      En reposo esta metrica vale **cero**: los servicios internos aceptan
      unicamente a la cuenta de servicio del orquestador, y esa ruta esta
      permitida de forma explicita. Un valor sostenido distinto de cero admite
      tres lecturas, en este orden de probabilidad:

      1. **Un despliegue reciente todavia propagando permisos.** Los cambios de
         IAM en Cloud Run tardan un par de minutos en surtir efecto, y durante
         ese tiempo las llamadas internas fallan. Se observo exactamente esto
         al desplegar el laboratorio.
      2. **Una ruta nueva que nadie autorizo.** Mira si hay un servicio
         recien anadido llamando a otro.
      3. **Alguien intentando invocar un servicio interno desde fuera.** Es el
         escenario para el que se protegieron los servicios con IAM en lugar
         de dejarlos publicos.

      La etiqueta `servicio` indica cual rechazo la llamada.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Mas de 10 rechazos en 5 minutos"

    condition_threshold {
      filter = "metric.type=\"logging.googleapis.com/user/seguridad/autorizacion_denegada\" AND resource.type=\"cloud_run_revision\""

      comparison      = "COMPARISON_GT"
      threshold_value = 10
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.servicio"]
      }
    }
  }

  severity              = "WARNING"
  notification_channels = [google_monitoring_notification_channel.correo.id]

  alert_strategy {
    auto_close = "3600s"
  }
}

resource "google_monitoring_alert_policy" "reconocimiento" {
  display_name = "Seguridad — sondeo de rutas inexistentes"
  combiner     = "OR"

  documentation {
    subject   = "Volumen inusual de peticiones a rutas que no existen"
    content   = <<-EOT
      Mas de veinte peticiones a rutas inexistentes en cinco minutos.

      Una aplicacion con clientes legitimos produce muy pocos 404: los
      clientes conocen sus endpoints. Un volumen alto es el patron clasico de
      alguien probando rutas a ver que encuentra.

      **Antes de escalar**, mira la etiqueta `ruta`. Si los caminos son del
      tipo `/admin`, `/.env` o `/wp-login.php`, es un escaneo automatizado de
      fondo y no va dirigido a este sistema en particular. Si en cambio son
      variaciones de rutas reales de la API, alguien esta explorando a mano.

      El umbral no es arbitrario: por debajo de el no se distingue de los
      errores de integracion de un cliente mal configurado.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Mas de 20 rutas inexistentes en 5 minutos"

    condition_threshold {
      filter = "metric.type=\"logging.googleapis.com/user/seguridad/reconocimiento\" AND resource.type=\"cloud_run_revision\""

      comparison      = "COMPARISON_GT"
      threshold_value = 20
      duration        = "300s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  severity              = "WARNING"
  notification_channels = [google_monitoring_notification_channel.correo.id]

  alert_strategy {
    auto_close = "3600s"
  }
}

resource "google_monitoring_alert_policy" "exfiltracion" {
  display_name = "Seguridad — volumen de salida inusual"
  combiner     = "OR"

  documentation {
    subject   = "Los servicios estan devolviendo mas datos de lo habitual"
    content   = <<-EOT
      El percentil 99 del tamano de respuesta supera los
      ${var.umbral_respuesta_maxima_kb} KB.

      Las respuestas de esta API son objetos JSON de unos cientos de bytes, de
      modo que alcanzar ese volumen requiere o un pico de trafico legitimo muy
      por encima de lo normal, o respuestas mucho mayores de lo que ningun
      endpoint deberia devolver.

      Se vigila el TAMANO DE LA MAYOR RESPUESTA y no el volumen agregado, y la
      diferencia importa: un pico de trafico legitimo multiplica el total pero
      no cambia cuanto devuelve cada peticion. Una extraccion masiva de datos
      si lo cambia, aunque sean cuatro peticiones y el total apenas se mueva.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Respuesta individual por encima de ${var.umbral_respuesta_maxima_kb} KB"

    condition_threshold {
      filter = "metric.type=\"logging.googleapis.com/user/seguridad/salida_bytes\" AND resource.type=\"cloud_run_revision\""

      comparison      = "COMPARISON_GT"
      threshold_value = var.umbral_respuesta_maxima_kb * 1024
      duration        = "600s"

      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_PERCENTILE_99"
      }
    }
  }

  severity              = "WARNING"
  notification_channels = [google_monitoring_notification_channel.correo.id]

  alert_strategy {
    auto_close = "3600s"
  }
}

# ════════════════════════════════════════════════════════════════════════════
# Panel — Senales Doradas de Seguridad
# ════════════════════════════════════════════════════════════════════════════
resource "google_monitoring_dashboard" "seguridad" {
  dashboard_json = jsonencode({
    displayName = "Senales Doradas de Seguridad"

    mosaicLayout = {
      columns = 12
      tiles = [
        {
          width = 12, height = 1, xPos = 0, yPos = 0
          widget = {
            text = {
              content = join("\n", [
                "## Senales Doradas de Seguridad",
                "",
                "Las cuatro senales doradas clasicas describen la **salud** del sistema.",
                "Un sistema bajo intrusion puede tenerlas las cuatro en verde.",
                "Este panel responde a las otras cuatro preguntas: a quien se le niega",
                "el paso, quien cambia la plataforma, quien sondea, y cuanto sale.",
              ])
              format = "MARKDOWN"
            }
          }
        },

        {
          width = 6, height = 4, xPos = 0, yPos = 1
          widget = {
            title = "Invocaciones rechazadas por IAM"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"logging.googleapis.com/user/seguridad/autorizacion_denegada\""
                    aggregation = {
                      alignmentPeriod    = "300s"
                      perSeriesAligner   = "ALIGN_SUM"
                      crossSeriesReducer = "REDUCE_SUM"
                      groupByFields      = ["metric.label.servicio"]
                    }
                  }
                }
                plotType = "STACKED_BAR"
              }]
              thresholds = [{ value = 10, label = "umbral de alerta" }]
              yAxis      = { label = "403 / 5 min", scale = "LINEAR" }
            }
          }
        },
        {
          width = 6, height = 4, xPos = 6, yPos = 1
          widget = {
            title = "Actividad administrativa, por identidad"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"logging.googleapis.com/user/seguridad/actividad_administrativa\""
                    aggregation = {
                      alignmentPeriod    = "300s"
                      perSeriesAligner   = "ALIGN_SUM"
                      crossSeriesReducer = "REDUCE_SUM"
                      groupByFields      = ["metric.label.identidad"]
                    }
                  }
                }
                plotType = "STACKED_BAR"
              }]
              yAxis = { label = "cambios / 5 min", scale = "LINEAR" }
            }
          }
        },

        {
          width = 6, height = 4, xPos = 0, yPos = 5
          widget = {
            title = "Sondeo de rutas inexistentes"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"logging.googleapis.com/user/seguridad/reconocimiento\""
                    aggregation = {
                      alignmentPeriod    = "300s"
                      perSeriesAligner   = "ALIGN_SUM"
                      crossSeriesReducer = "REDUCE_SUM"
                      groupByFields      = ["metric.label.ruta"]
                    }
                  }
                }
                plotType = "STACKED_BAR"
              }]
              thresholds = [{ value = 20, label = "umbral de alerta" }]
              yAxis      = { label = "404 / 5 min", scale = "LINEAR" }
            }
          }
        },
        {
          width = 6, height = 4, xPos = 6, yPos = 5
          widget = {
            title = "Tamano de respuesta (p99)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"logging.googleapis.com/user/seguridad/salida_bytes\""
                    aggregation = {
                      alignmentPeriod    = "600s"
                      perSeriesAligner   = "ALIGN_PERCENTILE_99"
                      crossSeriesReducer = "REDUCE_MAX"
                      groupByFields      = ["metric.label.servicio"]
                    }
                  }
                }
                plotType = "LINE"
              }]
              thresholds = [{
                value = var.umbral_respuesta_maxima_kb * 1024
                label = "umbral de alerta"
              }]
              yAxis = { label = "bytes por respuesta", scale = "LINEAR" }
            }
          }
        },

        {
          width = 12, height = 1, xPos = 0, yPos = 9
          widget = {
            text = {
              content = join("\n", [
                "### Como leer este panel",
                "",
                "- **Cero no es ausencia de datos.** Los paneles de rechazos y sondeo",
                "  valen cero cuando todo esta bien. Si llevan mucho tiempo planos,",
                "  confirma que las metricas siguen recibiendo logs antes de confiar.",
                "- **Un 403 no siempre es un ataque**: lo mas comun es un despliegue",
                "  reciente con los permisos todavia propagandose.",
                "- **Se vigila el tamano de cada respuesta, no el volumen total.** Un",
                "  pico de trafico legitimo no cambia cuanto devuelve cada peticion.",
              ])
              format = "MARKDOWN"
            }
          }
        },
      ]
    }
  })

  depends_on = [google_project_service.requeridas]
}
