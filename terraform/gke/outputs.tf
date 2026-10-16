# ════════════════════════════════════════════════════════════════════════════
# Salidas — las consume scripts/desplegar-gke.sh
# ════════════════════════════════════════════════════════════════════════════

output "project_id" {
  description = "Proyecto en el que vive el cluster; lo lee el script de despliegue"
  value       = var.project_id
}

output "cluster_nombre" {
  description = "Nombre del cluster"
  value       = google_container_cluster.mesh.name
}

output "cluster_zona" {
  description = "Zona del cluster"
  value       = google_container_cluster.mesh.location
}

output "comando_credenciales" {
  description = "Comando que configura kubectl contra este cluster"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.mesh.name} --zone ${google_container_cluster.mesh.location} --project ${var.project_id}"
}

output "collector_service_account" {
  description = "Cuenta de GCP que asume el Collector; va en la anotacion de Workload Identity"
  value       = google_service_account.collector.email
}

output "registry" {
  description = "Prefijo de las imagenes en Artifact Registry"
  value       = local.registry
}

output "red" {
  description = "VPC y subred del cluster, para consultar los Flow Logs del Modulo C"
  value = {
    vpc    = google_compute_network.mesh.name
    subred = google_compute_subnetwork.nodos.name
  }
}

output "consulta_flow_logs" {
  description = "Filtro de Cloud Logging que devuelve los flujos de red del cluster"
  value       = "resource.type=\"gce_subnetwork\" AND resource.labels.subnetwork_name=\"${google_compute_subnetwork.nodos.name}\""
}
