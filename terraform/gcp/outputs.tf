# ════════════════════════════════════════════════════════════════════════════
# Salidas del despliegue en GCP
#
# Los enlaces directos a la consola evitan tener que navegar por la UI para
# capturar las evidencias del entregable.
# ════════════════════════════════════════════════════════════════════════════

output "service_a_url" {
  description = "URL pública de service-a — punto de entrada para el benchmark"
  value       = google_cloud_run_v2_service.service_a.uri
}

output "service_b_url" {
  description = "URL interna de service-b (no alcanzable desde internet)"
  value       = google_cloud_run_v2_service.service_b.uri
}

output "service_account" {
  description = "Service account que usan los servicios y el sidecar del Collector"
  value       = google_service_account.runtime.email
}

output "artifact_registry" {
  description = "Destino al que hay que publicar las imágenes antes del primer apply"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo_name}"
}

output "cloud_sql_connection" {
  description = "Nombre de conexión de Cloud SQL"
  value       = var.enable_cloud_sql ? google_sql_database_instance.postgres[0].connection_name : "deshabilitado"
}

output "consola_cloud_trace" {
  description = "Trazas distribuidas en la consola de GCP"
  value       = "https://console.cloud.google.com/traces/list?project=${var.project_id}"
}

output "consola_cloud_logging" {
  description = "Logs con trace_id; el filtro deja solo los del laboratorio"
  value       = "https://console.cloud.google.com/logs/query;query=logName%3D%22projects%2F${var.project_id}%2Flogs%2Fotel-lab%22?project=${var.project_id}"
}

output "consola_managed_prometheus" {
  description = "Métricas en Managed Prometheus"
  value       = "https://console.cloud.google.com/monitoring/metrics-explorer?project=${var.project_id}"
}

output "comandos_publicacion" {
  description = "Secuencia para construir y publicar las imágenes antes del apply"
  value = <<-EOT

    1. Autenticar Docker contra Artifact Registry:
       gcloud auth configure-docker ${var.region}-docker.pkg.dev

    2. Construir y publicar ambas imágenes (desde la raíz del repositorio):
       docker build -t ${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo_name}/service-a:${var.app_version} -f services/service-a/Dockerfile services/
       docker build -t ${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo_name}/service-b:${var.app_version} -f services/service-b/Dockerfile services/

       docker push ${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo_name}/service-a:${var.app_version}
       docker push ${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo_name}/service-b:${var.app_version}

    3. Aplicar la infraestructura:
       terraform apply -var-file=terraform.tfvars

  EOT
}
