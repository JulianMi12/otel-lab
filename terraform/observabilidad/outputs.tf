output "politicas_que_notifican" {
  description = "Alertas conectadas al canal de correo"
  value = [
    google_monitoring_alert_policy.correlacion_multisenal.display_name,
    google_monitoring_alert_policy.presupuesto_error.display_name,
    google_monitoring_alert_policy.ausencia_de_senal.display_name,
    google_monitoring_alert_policy.autorizacion_denegada.display_name,
    google_monitoring_alert_policy.reconocimiento.display_name,
    google_monitoring_alert_policy.exfiltracion.display_name,
  ]
}

output "politicas_de_referencia" {
  description = "Umbrales fijos que NO notifican; existen para la comparacion del Modulo B"
  value = var.desplegar_referencias ? [
    google_monitoring_alert_policy.umbral_estricto.display_name,
    google_monitoring_alert_policy.umbral_laxo.display_name,
  ] : []
}

output "panel_seguridad" {
  description = "URL del panel de Senales Doradas de Seguridad"
  value       = "https://console.cloud.google.com/monitoring/dashboards/builder/${basename(google_monitoring_dashboard.seguridad.id)}?project=${var.project_id}"
}

output "metricas_de_seguridad" {
  description = "Metricas derivadas de logs creadas por el Modulo C"
  value = [
    google_logging_metric.autorizacion_denegada.name,
    google_logging_metric.actividad_administrativa.name,
    google_logging_metric.reconocimiento.name,
    google_logging_metric.salida_bytes.name,
  ]
}
