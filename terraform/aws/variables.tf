# ════════════════════════════════════════════════════════════════════════════
# Variables del despliegue en AWS (ECS Fargate)
# ════════════════════════════════════════════════════════════════════════════

variable "region" {
  description = "Region de AWS donde se despliega el laboratorio"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo de nombre para todos los recursos creados"
  type        = string
  default     = "otel-lab"
}

variable "environment" {
  description = "Nombre del entorno; se propaga como deployment.environment en la telemetria"
  type        = string
  default     = "production"
}

variable "app_version" {
  description = "Version de la aplicacion, usada como etiqueta de imagen en ECR"
  type        = string
  default     = "1.0.0"
}

# ── Red ─────────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "Bloque CIDR de la VPC del laboratorio"
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = <<-EOT
    Numero de zonas de disponibilidad.
    ECS Fargate detras de un ALB exige subredes en al menos dos AZ.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "Se requieren al menos 2 zonas de disponibilidad para el ALB."
  }
}

variable "use_nat_gateway" {
  description = <<-EOT
    Crea un NAT Gateway para dar salida a internet a las tasks privadas.
    Es el recurso mas caro de este despliegue (~32 USD/mes por AZ). Con false
    las tasks se colocan en subredes publicas con IP asignada, lo que abarata
    el laboratorio a costa de una postura de red menos estricta.
  EOT
  type        = bool
  default     = false
}

# ── ECS ─────────────────────────────────────────────────────────────────────
variable "task_cpu" {
  description = "Unidades de CPU por task (1024 = 1 vCPU). Cubre app + sidecar"
  type        = number
  default     = 1024
}

variable "task_memory" {
  description = "Memoria por task en MiB. Debe cubrir la app mas el Collector"
  type        = number
  default     = 2048
}

variable "app_cpu" {
  description = "Unidades de CPU reservadas al contenedor de la aplicacion"
  type        = number
  default     = 768
}

variable "collector_cpu" {
  description = "Unidades de CPU reservadas al sidecar del Collector"
  type        = number
  default     = 256
}

variable "collector_memory" {
  description = "Memoria en MiB del sidecar del Collector"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Numero de tasks por servicio"
  type        = number
  default     = 1
}

# ── Base de datos ───────────────────────────────────────────────────────────
variable "enable_rds" {
  description = "Crea una instancia RDS PostgreSQL. Es el recurso con costo por hora continuo"
  type        = bool
  default     = true
}

variable "db_instance_class" {
  description = "Clase de la instancia RDS. db.t4g.micro entra en la capa gratuita"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_name" {
  description = "Nombre de la base de datos"
  type        = string
  default     = "appdb"
}

variable "db_user" {
  description = "Usuario maestro de la base de datos"
  type        = string
  default     = "app"
}

variable "db_password" {
  description = "Password de la base de datos. Se guarda en Secrets Manager"
  type        = string
  sensitive   = true
}

# ── Observabilidad ──────────────────────────────────────────────────────────
variable "log_retention_days" {
  description = "Retencion de los grupos de CloudWatch Logs. Acota el costo de almacenamiento"
  type        = number
  default     = 7
}

variable "tags" {
  description = "Etiquetas aplicadas a todos los recursos"
  type        = map(string)
  default = {
    Proyecto   = "otel-lab"
    Curso      = "observabilidad"
    Gestionado = "terraform"
  }
}
