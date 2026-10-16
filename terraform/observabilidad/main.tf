# ════════════════════════════════════════════════════════════════════════════
# Alertas, paneles y postura de seguridad (Modulos B y C)
#
# Raiz de Terraform separada de los despliegues. La razon es de ciclo de vida:
# el cluster de GKE se crea y se destruye en el mismo dia, pero las politicas
# de alerta y los paneles describen COMO SE OBSERVA el sistema y deben
# sobrevivir a cualquiera de los despliegues concretos. Si vivieran dentro de
# terraform/gke, destruir el cluster borraria tambien la definicion de los
# SLO, que es justo lo que no debe pasar.
#
# Cubre:
#   aiops.tf      Modulo B — deteccion de anomalias y correlacion multi-senal
#   seguridad.tf  Modulo C — observabilidad de red y seguridad
# ════════════════════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_project_service" "requeridas" {
  for_each = toset([
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "cloudtrace.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# ── Canal de notificacion ───────────────────────────────────────────────────
# Correo, no PagerDuty ni Slack, porque es el unico canal que no exige una
# integracion externa con credenciales propias. Lo que importa del laboratorio
# no es el transporte sino el CONTENIDO del aviso: si lleva el trace_id y el
# contexto suficiente para actuar.
resource "google_monitoring_notification_channel" "correo" {
  display_name = "Guardia del laboratorio"
  type         = "email"

  labels = {
    email_address = var.email_alertas
  }

  depends_on = [google_project_service.requeridas]
}
