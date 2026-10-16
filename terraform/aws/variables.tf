# ════════════════════════════════════════════════════════════════════════════
# Variables del despliegue en AWS (ECS Fargate)
# ════════════════════════════════════════════════════════════════════════════

variable "aws_profile" {
  description = <<-EOT
    Perfil del AWS CLI con el que se despliega.

    Se exige explicitamente y SIN valor por defecto a proposito. Si se dejara
    vacio, Terraform usaria el perfil "default", que en un equipo de trabajo
    suele ser la cuenta de la empresa: un `apply` descuidado crearia VPC, ECS
    y RDS en infraestructura corporativa. Obligar a nombrarlo convierte ese
    error silencioso en un fallo inmediato de `terraform plan`.
  EOT
  type        = string
}

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


# ── Chaos Engineering (Modulo D) ────────────────────────────────────────────
# Se exponen como variables de Terraform, y no como cambios de codigo, para
# que el experimento sea reproducible y quede registrado en el estado: se
# puede ver cuando se activo el caos y con que valores.
variable "chaos_latency_ms" {
  description = "Latencia artificial en data-service, en ms. 0 lo desactiva"
  type        = number
  default     = 0
}

variable "chaos_error_rate" {
  description = <<-EOT
    Proporcion de peticiones que data-service fallara deliberadamente (0 a 1).
    El Modulo D pide 0.1, es decir un 10 %. En reposo debe quedar en 0.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.chaos_error_rate >= 0 && var.chaos_error_rate <= 1
    error_message = "chaos_error_rate debe estar entre 0 y 1."
  }
}

# ── Modulo C: seguridad ─────────────────────────────────────────────────────
variable "email_alertas" {
  description = <<-EOT
    Direccion suscrita al topico SNS de seguridad. Cadena vacia desactiva la
    suscripcion.
    AWS envia un correo de confirmacion y la suscripcion queda "pending" hasta
    que alguien pulsa el enlace: un apply limpio NO garantiza que las alarmas
    lleguen a ninguna parte.
  EOT
  type        = string
  default     = ""
}

variable "umbral_exfiltracion_mb" {
  description = <<-EOT
    Volumen de salida, en MB por periodo de cinco minutos, que dispara la
    alarma. Lo que importa no es el numero sino que exista una linea base
    contra la que comparar.
  EOT
  type        = number
  default     = 50
}

variable "habilitar_seguridad_avanzada" {
  description = <<-EOT
    Activa GuardDuty y Security Hub.
    Son los unicos servicios de seguridad.tf cuyo coste crece con el uso y no
    con el tiempo: GuardDuty cobra por volumen analizado y Security Hub por
    comprobacion ejecutada. Treinta dias de prueba gratuita cubren la
    demostracion, pero hay que acordarse de apagarlos despues.
  EOT
  type        = bool
  default     = false
}

# ── Acceso de personas ──────────────────────────────────────────────────────
variable "usuarios" {
  description = <<-EOT
    Personas con acceso a la consola, como mapa de correo a nivel.
    Niveles validos: "administrador" (crea y destruye infraestructura) y
    "lectura" (inspecciona sin modificar).
    Vacio por defecto: un usuario de consola es una credencial viva y no debe
    existir mientras no haga falta.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for nivel in values(var.usuarios) : contains(["administrador", "lectura"], nivel)
    ])
    error_message = "Cada usuario debe tener nivel \"administrador\" o \"lectura\"."
  }
}

variable "zonas" {
  description = <<-EOT
    Zonas de disponibilidad, nombradas de forma explicita.
    Si se deja vacio se consultan con `aws_availability_zones`. Fijarlas hace
    el despliegue reproducible: el orden que devuelve esa API no esta
    garantizado, y un apply posterior podia mover las subredes de zona sin que
    nadie lo pidiera.
  EOT
  type        = list(string)
  default     = []
}
