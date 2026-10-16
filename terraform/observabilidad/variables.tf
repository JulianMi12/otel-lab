# ════════════════════════════════════════════════════════════════════════════
# Variables de alertas, paneles y seguridad
# ════════════════════════════════════════════════════════════════════════════

variable "project_id" {
  description = "ID del proyecto de GCP. Sin valor por defecto: obliga a nombrarlo"
  type        = string
}

variable "region" {
  description = "Region por defecto"
  type        = string
  default     = "us-central1"
}

variable "email_alertas" {
  description = "Direccion que recibe las notificaciones de las politicas criticas"
  type        = string
}

variable "desplegar_metricas_malla" {
  description = <<-EOT
    Crea tambien las metricas que miden los logs de acceso de los sidecars de
    Istio. Solo tienen sentido con el cluster levantado: sin el no recibirian
    un solo dato, y un panel vacio parece funcionar hasta que alguien lo mira
    de cerca.
  EOT
  type        = bool
  default     = false
}

variable "subred_cluster" {
  description = <<-EOT
    Nombre de la subred cuyos Flow Logs se analizan en el Modulo C.
    Debe coincidir con la que crea terraform/gke (output `red.subred`).
  EOT
  type        = string
  default     = "otel-lab-mesh-subnet"
}

# ── Objetivos de nivel de servicio ──────────────────────────────────────────
# Mismos valores que usan el dashboard de Grafana y aiops/detector.py. Estar
# definidos en tres sitios es un riesgo conocido; estan documentados en cada
# uno para que una discrepancia se detecte al leer, no en una guardia.
variable "slo_p99_ms" {
  description = "Objetivo de latencia p99 en milisegundos"
  type        = number
  default     = 1000
}

variable "slo_disponibilidad_pct" {
  description = "Objetivo de disponibilidad en porcentaje"
  type        = number
  default     = 99.5

  validation {
    condition     = var.slo_disponibilidad_pct > 0 && var.slo_disponibilidad_pct < 100
    error_message = "El SLO de disponibilidad debe estar entre 0 y 100, sin incluirlos."
  }
}

variable "factor_quemado" {
  description = <<-EOT
    Multiplicador de consumo del presupuesto de error que dispara la alerta.
    14.4 es el valor del SRE Workbook para quemado rapido: agota un
    presupuesto mensual en dos dias.
  EOT
  type        = number
  default     = 14.4
}

variable "desplegar_referencias" {
  description = <<-EOT
    Crea las dos politicas de umbral fijo que sirven de termino de comparacion
    del Modulo B. No notifican a nadie: existen para poder contar cuantas
    veces habrian interrumpido a una persona.
    Ponlo en false si el proyecto no debe acumular politicas de ejemplo.
  EOT
  type        = bool
  default     = true
}

# ── Seguridad ───────────────────────────────────────────────────────────────
variable "umbral_exfiltracion_mb" {
  description = <<-EOT
    Volumen de salida hacia internet, en MB por cada diez minutos, a partir
    del cual se abre una alerta.
    El valor correcto depende del sistema: lo que importa no es el numero sino
    que exista una linea base contra la que comparar. 50 MB es holgado para
    este laboratorio, donde la salida legitima son las exportaciones de
    telemetria y la descarga ocasional de imagenes.
  EOT
  type        = number
  default     = 50
}

variable "umbral_respuesta_maxima_kb" {
  description = <<-EOT
    Tamano, en KB, a partir del cual una respuesta individual se considera
    anomala. Las respuestas de esta API son objetos JSON de unos cientos de
    bytes; 256 KB deja margen de sobra y sigue siendo tres ordenes de magnitud
    menos que una extraccion masiva.
  EOT
  type        = number
  default     = 256
}
