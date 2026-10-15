# ════════════════════════════════════════════════════════════════════════════
# Variables del despliegue en GCP
#
# Ningun valor de cuenta esta quemado en el codigo: todos se pasan por
# terraform.tfvars (que esta en .gitignore) o por -var en la linea de comandos.
# ════════════════════════════════════════════════════════════════════════════

variable "project_id" {
  description = "ID del proyecto de GCP donde se despliega el laboratorio"
  type        = string

  validation {
    condition     = length(var.project_id) > 5
    error_message = "project_id debe ser el identificador real del proyecto, no su nombre."
  }
}

variable "region" {
  description = "Region de GCP para Cloud Run, Artifact Registry y Cloud SQL"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Nombre del entorno; se propaga como deployment.environment en toda la telemetria"
  type        = string
  default     = "production"
}

variable "app_version" {
  description = "Version de la aplicacion, usada como etiqueta de imagen y en el Resource de OTel"
  type        = string
  default     = "1.0.0"
}

# ── Base de datos ───────────────────────────────────────────────────────────
variable "enable_cloud_sql" {
  description = <<-EOT
    Crea una instancia de Cloud SQL para PostgreSQL.
    Se expone como variable porque es el unico recurso del laboratorio con
    costo por hora continuo: con creditos limitados conviene poder apagarlo.
  EOT
  type        = bool
  default     = true
}

variable "db_tier" {
  description = "Tier de Cloud SQL. db-f1-micro es el mas economico y suficiente para el lab"
  type        = string
  default     = "db-f1-micro"
}

variable "db_name" {
  description = "Nombre de la base de datos de la aplicacion"
  type        = string
  default     = "appdb"
}

variable "db_user" {
  description = "Usuario de la base de datos"
  type        = string
  default     = "app"
}

variable "db_password" {
  description = "Password de la base de datos. Se guarda en Secret Manager, nunca en el estado en claro"
  type        = string
  sensitive   = true
}

# ── Cloud Run ───────────────────────────────────────────────────────────────
variable "service_cpu" {
  description = "CPU asignada a cada servicio de Cloud Run"
  type        = string
  default     = "1"
}

variable "service_memory" {
  description = "Memoria por servicio. Debe cubrir la app mas el sidecar del Collector"
  type        = string
  default     = "1Gi"
}

variable "collector_memory" {
  description = "Memoria del contenedor sidecar del OTel Collector"
  type        = string
  default     = "512Mi"
}

variable "min_instances" {
  description = <<-EOT
    Instancias minimas por servicio.
    Con 0 el servicio escala a cero y no genera costo en reposo, pero el primer
    request paga un arranque en frio que distorsiona las mediciones de latencia.
  EOT
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Instancias maximas; acota el gasto maximo ante una rafaga de trafico"
  type        = number
  default     = 3
}

variable "allow_public_access" {
  description = "Permite invocar service-a sin autenticacion (necesario para la demo y el benchmark)"
  type        = bool
  default     = true
}

# ── Observabilidad ──────────────────────────────────────────────────────────
variable "trace_sampling_ratio" {
  description = <<-EOT
    Fraccion de trazas exportadas a Cloud Trace (0.0 a 1.0).
    En el laboratorio se usa 1.0 para que toda traza generada sea visible como
    evidencia; en produccion este valor se bajaria para controlar el costo.
  EOT
  type        = number
  default     = 1.0

  validation {
    condition     = var.trace_sampling_ratio > 0 && var.trace_sampling_ratio <= 1
    error_message = "trace_sampling_ratio debe estar entre 0 (exclusivo) y 1 (inclusivo)."
  }
}

variable "artifact_repo_name" {
  description = "Nombre del repositorio de Artifact Registry que aloja las imagenes"
  type        = string
  default     = "otel-lab"
}

variable "labels" {
  description = "Etiquetas aplicadas a todos los recursos facturables"
  type        = map(string)
  default = {
    proyecto   = "otel-lab"
    curso      = "observabilidad"
    gestionado = "terraform"
  }
}
