# ════════════════════════════════════════════════════════════════════════════
# Variables del acceso de personas
# ════════════════════════════════════════════════════════════════════════════

variable "aws_profile" {
  description = <<-EOT
    Perfil del AWS CLI. Se exige explicitamente y SIN valor por defecto a
    proposito: si se dejara vacio, Terraform usaria el perfil "default", que
    en un equipo de trabajo suele ser la cuenta de la empresa. Crear usuarios
    con acceso a la consola en infraestructura corporativa por descuido es
    exactamente el error que esta linea impide.
  EOT
  type        = string
}

variable "region" {
  description = "Region del proveedor. IAM es global; solo afecta a donde se dirigen las llamadas"
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Prefijo de nombre, para que los recursos sean identificables"
  type        = string
  default     = "otel-lab"
}

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

variable "tags" {
  description = "Etiquetas aplicadas a los usuarios"
  type        = map(string)
  default = {
    Proyecto   = "otel-lab"
    Curso      = "observabilidad"
    Gestionado = "terraform"
  }
}
