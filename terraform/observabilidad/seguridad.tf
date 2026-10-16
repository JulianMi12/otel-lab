# ════════════════════════════════════════════════════════════════════════════
# Modulo C — Observabilidad de red y seguridad
#
# La idea que organiza este archivo: las cuatro senales doradas de Google
# (latencia, trafico, errores, saturacion) describen la SALUD de un sistema,
# pero no dicen nada sobre si alguien lo esta atacando. Un sistema bajo
# intrusion puede tener las cuatro en verde.
#
# Lo que sigue define el equivalente para seguridad, con la misma disciplina:
# pocas senales, cada una con una pregunta concreta detras.
#
#   Autenticacion   ¿Quien intenta entrar y no lo consigue?
#   Autorizacion    ¿Quien, ya dentro, pide lo que no le corresponde?
#   Cifrado         ¿Queda trafico interno sin proteger?
#   Exfiltracion    ¿Esta saliendo mas informacion de la habitual?
#
# Las cuatro se construyen sobre senales que YA se estan recogiendo: los VPC
# Flow Logs de la subred del cluster y los logs de acceso L7 que emiten los
# sidecars de Istio. No hay agentes nuevos ni instrumentacion extra.
# ════════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════════
# Metricas derivadas de logs
#
# Un log-based metric convierte un flujo de texto en una serie temporal. Es lo
# que permite graficar y alertar sobre algo que nacio como una linea de log, y
# sale mucho mas barato que conservar los logs crudos: la metrica se retiene
# durante meses, el log que la produjo puede caducar en dias.
# ════════════════════════════════════════════════════════════════════════════

# ── 1. Autorizacion denegada en la malla ────────────────────────────────────
# Istio devuelve 403 con el cuerpo "RBAC: access denied" cuando una
# AuthorizationPolicy rechaza la llamada. Es la senal mas directa de
# movimiento lateral: alguien que ya esta dentro del cluster intentando hablar
# con un servicio que no le corresponde.
resource "google_logging_metric" "autorizacion_denegada" {
  name   = "seguridad/autorizacion_denegada"
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

    labels {
      key         = "destino"
      value_type  = "STRING"
      description = "Servicio al que intentaba llegar"
    }
  }

  label_extractors = {
    # El principal SPIFFE llega como spiffe://cluster.local/ns/<ns>/sa/<sa>.
    # Se guarda entero: saber que CUENTA DE SERVICIO fue rechazada es mas util
    # que saber que Pod, porque el Pod es efimero y la identidad no.
    "origen"  = "EXTRACT(jsonPayload.origen)"
    "destino" = "EXTRACT(jsonPayload.destino)"
  }

  depends_on = [google_project_service.requeridas]
}

# ── 2. Trafico interno sin cifrar ───────────────────────────────────────────
# Con PeerAuthentication en STRICT esta metrica deberia quedarse en cero
# siempre. Precisamente por eso es util: cualquier valor distinto de cero
# significa que alguien ha desplegado una excepcion, que un Pod no recibio
# sidecar, o que hay una carga fuera de la malla hablando en claro.
resource "google_logging_metric" "trafico_sin_mtls" {
  name   = "seguridad/trafico_sin_mtls"
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

    labels {
      key         = "destino"
      value_type  = "STRING"
      description = "Servicio que acepto la conexion sin cifrar"
    }
  }

  label_extractors = {
    "destino" = "EXTRACT(jsonPayload.destino)"
  }

  depends_on = [google_project_service.requeridas]
}

# ── 3. Conexiones de red bloqueadas ─────────────────────────────────────────
# Las reglas de firewall de terraform/gke tienen logging activado. Una regla
# que deniega en silencio protege igual de bien, pero no genera la senal que
# permite saber que alguien lo intento: la diferencia entre estar protegido y
# saber que te estan probando.
resource "google_logging_metric" "conexiones_bloqueadas" {
  name   = "seguridad/conexiones_bloqueadas"
  filter = <<-EOT
    resource.type="gce_subnetwork"
    log_id("compute.googleapis.com/firewall")
    jsonPayload.disposition="DENIED"
  EOT

  description = "Conexiones rechazadas por reglas de firewall de la VPC"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "puerto"
      value_type  = "STRING"
      description = "Puerto de destino del intento"
    }

    labels {
      key         = "direccion"
      value_type  = "STRING"
      description = "INGRESS o EGRESS"
    }
  }

  label_extractors = {
    "puerto"    = "EXTRACT(jsonPayload.connection.dest_port)"
    "direccion" = "EXTRACT(jsonPayload.rule_details.direction)"
  }

  depends_on = [google_project_service.requeridas]
}

# ── 4. Volumen de salida hacia internet ─────────────────────────────────────
# De los VPC Flow Logs. Se filtran los destinos externos porque el trafico
# interno entre Pods es, por volumen, varios ordenes de magnitud mayor y
# enterraria completamente la senal que interesa.
resource "google_logging_metric" "salida_a_internet_bytes" {
  name   = "seguridad/salida_a_internet_bytes"
  filter = <<-EOT
    resource.type="gce_subnetwork"
    resource.labels.subnetwork_name="${var.subred_cluster}"
    log_id("compute.googleapis.com/vpc_flows")
    jsonPayload.dest_instance.vm_name=""
    jsonPayload.reporter="SRC"
  EOT

  description = "Bytes enviados desde el cluster hacia destinos fuera de la VPC"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "By"

    labels {
      key         = "pais_destino"
      value_type  = "STRING"
      description = "Pais del destino, segun la geolocalizacion del Flow Log"
    }
  }

  # El valor de la metrica no es el numero de lineas sino los bytes que lleva
  # cada una. Sin value_extractor se contarian conexiones, y una exfiltracion
  # es precisamente pocas conexiones con mucho volumen.
  value_extractor = "EXTRACT(jsonPayload.bytes_sent)"

  label_extractors = {
    "pais_destino" = "EXTRACT(jsonPayload.dest_location.country)"
  }

  depends_on = [google_project_service.requeridas]
}

# ════════════════════════════════════════════════════════════════════════════
# Alertas de seguridad
# ════════════════════════════════════════════════════════════════════════════

resource "google_monitoring_alert_policy" "movimiento_lateral" {
  display_name = "Seguridad — posible movimiento lateral"
  combiner     = "OR"

  documentation {
    subject   = "Varias peticiones rechazadas por politicas de autorizacion"
    content   = <<-EOT
      La malla ha rechazado mas de diez peticiones en cinco minutos por falta
      de autorizacion (403, `RBAC: access denied`).

      En reposo esta metrica vale **cero**: las rutas legitimas estan todas
      permitidas de forma explicita en `k8s/41-istio-seguridad.yaml`. Un valor
      sostenido distinto de cero solo admite dos lecturas, y conviene
      descartarlas en este orden:

      1. **Un despliegue nuevo con una ruta que nadie autorizo.** Es lo mas
         probable y lo menos grave. Mira si ha habido un rollout reciente.
      2. **Un Pod comprometido probando que mas alcanza.** Es el escenario
         para el que se diseno la politica de denegacion por defecto.

      El `origen` de la metrica trae la identidad SPIFFE del llamante
      rechazado, que identifica la cuenta de servicio y no el Pod: util
      porque el Pod es efimero y la identidad no.

      ```
      kubectl logs -n otel-lab -l app=<destino> -c istio-proxy | grep 'RBAC'
      ```
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Mas de 10 denegaciones en 5 minutos"

    condition_threshold {
      filter = "metric.type=\"logging.googleapis.com/user/seguridad/autorizacion_denegada\" AND resource.type=\"k8s_container\""

      comparison      = "COMPARISON_GT"
      threshold_value = 10
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.origen"]
      }
    }
  }

  severity              = "CRITICAL"
  notification_channels = [google_monitoring_notification_channel.correo.id]

  alert_strategy {
    auto_close = "3600s"
  }
}

resource "google_monitoring_alert_policy" "mtls_roto" {
  display_name = "Seguridad — trafico interno sin cifrar"
  combiner     = "OR"

  documentation {
    subject   = "Hay trafico L7 sin identidad mTLS dentro de la malla"
    content   = <<-EOT
      Se ha observado trafico hacia un servicio de la malla sin certificado
      mTLS en el llamante.

      Con `PeerAuthentication` en `STRICT` esto **no deberia poder ocurrir**,
      asi que cualquier valor distinto de cero indica una de estas tres cosas:

      | Causa | Como confirmarlo |
      |---|---|
      | Un Pod arranco sin sidecar | `kubectl get pods -n otel-lab` debe dar 2/2 en todos |
      | Alguien desplego una excepcion `PERMISSIVE` | `kubectl get peerauthentication -A` |
      | Una carga fuera de la malla llama al servicio | Revisa el `destino` de la metrica |

      La primera es la mas comun: un Pod creado antes de etiquetar el
      namespace no recibe sidecar, y ademas de hablar en claro queda fuera de
      toda la telemetria de malla. Se arregla con `kubectl rollout restart`.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Cualquier peticion sin mTLS"

    condition_threshold {
      filter = "metric.type=\"logging.googleapis.com/user/seguridad/trafico_sin_mtls\" AND resource.type=\"k8s_container\""

      comparison      = "COMPARISON_GT"
      threshold_value = 0
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
    subject   = "El cluster esta enviando mas datos de lo habitual hacia internet"
    content   = <<-EOT
      La salida hacia destinos fuera de la VPC supera los
      ${var.umbral_exfiltracion_mb} MB en diez minutos.

      La salida legitima de este laboratorio son las exportaciones de
      telemetria a Cloud Trace, Cloud Logging y Managed Prometheus, mas la
      descarga ocasional de imagenes. Todo eso junto se queda muy por debajo
      del umbral.

      **Antes de escalar**, comprueba la etiqueta `pais_destino`. Un volumen
      alto hacia los rangos de Google es casi siempre telemetria o un pull de
      imagenes; un volumen alto hacia un destino que no aparece nunca en la
      linea base es otra cosa.

      El filtro que devuelve los flujos crudos:

      ```
      resource.type="gce_subnetwork"
      resource.labels.subnetwork_name="${var.subred_cluster}"
      log_id("compute.googleapis.com/vpc_flows")
      jsonPayload.dest_instance.vm_name=""
      ```

      Nota sobre el muestreo: los Flow Logs estan a `flow_sampling = 0.5`, asi
      que el volumen real es aproximadamente el doble del observado. El umbral
      ya lo tiene en cuenta.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Salida por encima de ${var.umbral_exfiltracion_mb} MB / 10 min"

    condition_threshold {
      filter = "metric.type=\"logging.googleapis.com/user/seguridad/salida_a_internet_bytes\" AND resource.type=\"gce_subnetwork\""

      comparison      = "COMPARISON_GT"
      threshold_value = var.umbral_exfiltracion_mb * 1024 * 1024
      duration        = "600s"

      aggregations {
        alignment_period   = "600s"
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

# ════════════════════════════════════════════════════════════════════════════
# Panel — Senales Doradas de Seguridad
#
# Cuatro filas, una por pregunta. El orden no es decorativo: va de lo externo
# a lo interno, que es el recorrido que hace un atacante y tambien el que hace
# quien investiga un incidente.
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
                "Este panel responde a las otras cuatro preguntas, de fuera hacia dentro:",
                "quien intenta entrar, quien pide de mas, que viaja sin cifrar, que sale.",
              ])
              format = "MARKDOWN"
            }
          }
        },

        # ── Fila 1: perimetro ─────────────────────────────────────────────
        {
          width = 6, height = 4, xPos = 0, yPos = 1
          widget = {
            title = "Conexiones bloqueadas por el firewall"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"logging.googleapis.com/user/seguridad/conexiones_bloqueadas\""
                    aggregation = {
                      alignmentPeriod    = "300s"
                      perSeriesAligner   = "ALIGN_SUM"
                      crossSeriesReducer = "REDUCE_SUM"
                      groupByFields      = ["metric.label.puerto"]
                    }
                  }
                }
                plotType = "STACKED_BAR"
              }]
              yAxis = { label = "intentos / 5 min", scale = "LINEAR" }
            }
          }
        },
        {
          width = 6, height = 4, xPos = 6, yPos = 1
          widget = {
            title = "Salida hacia internet (bytes)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"logging.googleapis.com/user/seguridad/salida_a_internet_bytes\""
                    aggregation = {
                      alignmentPeriod    = "600s"
                      perSeriesAligner   = "ALIGN_SUM"
                      crossSeriesReducer = "REDUCE_SUM"
                      groupByFields      = ["metric.label.pais_destino"]
                    }
                  }
                }
                plotType = "STACKED_AREA"
              }]
              thresholds = [{
                value     = var.umbral_exfiltracion_mb * 1024 * 1024
                color     = "RED"
                direction = "ABOVE"
                label     = "umbral de alerta"
              }]
              yAxis = { label = "bytes / 10 min", scale = "LINEAR" }
            }
          }
        },

        # ── Fila 2: dentro de la malla ────────────────────────────────────
        {
          width = 6, height = 4, xPos = 0, yPos = 5
          widget = {
            title = "Autorizacion denegada, por identidad del llamante"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"logging.googleapis.com/user/seguridad/autorizacion_denegada\""
                    aggregation = {
                      alignmentPeriod    = "300s"
                      perSeriesAligner   = "ALIGN_SUM"
                      crossSeriesReducer = "REDUCE_SUM"
                      groupByFields      = ["metric.label.origen"]
                    }
                  }
                }
                plotType = "STACKED_BAR"
              }]
              thresholds = [{
                value     = 10
                color     = "RED"
                direction = "ABOVE"
                label     = "umbral de movimiento lateral"
              }]
              yAxis = { label = "403 / 5 min", scale = "LINEAR" }
            }
          }
        },
        {
          width = 6, height = 4, xPos = 6, yPos = 5
          widget = {
            title = "Trafico interno sin mTLS (debe ser cero)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"logging.googleapis.com/user/seguridad/trafico_sin_mtls\""
                    aggregation = {
                      alignmentPeriod    = "300s"
                      perSeriesAligner   = "ALIGN_SUM"
                      crossSeriesReducer = "REDUCE_SUM"
                      groupByFields      = ["metric.label.destino"]
                    }
                  }
                }
                plotType = "LINE"
              }]
              yAxis = { label = "peticiones / 5 min", scale = "LINEAR" }
            }
          }
        },

        # ── Fila 3: contexto ──────────────────────────────────────────────
        {
          width = 12, height = 1, xPos = 0, yPos = 9
          widget = {
            text = {
              content = join("\n", [
                "### Como leer este panel",
                "",
                "- **Cero no es ausencia de datos.** Los dos paneles de la fila inferior",
                "  valen cero cuando todo esta bien. Si llevan mucho tiempo planos,",
                "  confirma que las metricas siguen recibiendo logs antes de confiar.",
                "- **El muestreo de Flow Logs es 0,5**: el volumen real es el doble.",
                "- **Un 403 no siempre es un ataque**: lo mas comun es un despliegue",
                "  nuevo con una ruta que nadie autorizo. Mira primero los rollouts.",
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
