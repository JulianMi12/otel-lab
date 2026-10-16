# ════════════════════════════════════════════════════════════════════════════
# Variables del cluster GKE con Istio
# ════════════════════════════════════════════════════════════════════════════

variable "project_id" {
  description = "ID del proyecto de GCP. Sin valor por defecto: obliga a nombrarlo"
  type        = string
}

variable "region" {
  description = "Region de GCP. El cluster se crea en la zona <region>-a"
  type        = string
  default     = "us-central1"
}

variable "project_name" {
  description = "Prefijo de nombre para los recursos del cluster"
  type        = string
  default     = "otel-lab"
}

variable "artifact_repo_name" {
  description = <<-EOT
    Repositorio de Artifact Registry del que se bajan las imagenes.
    Es el mismo que ya creo terraform/gcp/: el cluster lo consume, no lo crea,
    para que destruir el cluster no borre las imagenes que usa Cloud Run.
  EOT
  type        = string
  default     = "otel-lab"
}

variable "app_version" {
  description = "Etiqueta de las imagenes a desplegar en la malla"
  type        = string
  default     = "1.0.0"
}

# ── Red ─────────────────────────────────────────────────────────────────────
variable "subnet_cidr" {
  description = "Rango de los nodos"
  type        = string
  default     = "10.30.0.0/20"
}

variable "pods_cidr" {
  description = <<-EOT
    Rango secundario de los Pods. Debe ser amplio: GKE reserva por defecto un
    /24 por nodo, asi que un /16 soporta 256 nodos. Quedarse corto aqui es un
    error que solo se manifiesta al escalar, y que obliga a recrear el cluster.
  EOT
  type        = string
  default     = "10.31.0.0/16"
}

variable "services_cidr" {
  description = "Rango secundario de los Services (ClusterIP)"
  type        = string
  default     = "10.32.0.0/20"
}

variable "flow_log_sampling" {
  description = <<-EOT
    Fraccion de flujos de red que se registran (0 a 1), para el Modulo C.
    0.5 mantiene visibles los patrones de trafico sin que el volumen de
    Cloud Logging se dispare.
  EOT
  type        = number
  default     = 0.5

  validation {
    condition     = var.flow_log_sampling > 0 && var.flow_log_sampling <= 1
    error_message = "flow_log_sampling debe estar entre 0 (excluido) y 1."
  }
}

# ── Nodos ───────────────────────────────────────────────────────────────────
variable "machine_type" {
  description = <<-EOT
    Tipo de maquina de los nodos.
    e2-standard-2 (2 vCPU, 8 GiB) es el minimo razonable: el plano de control
    de Istio pide 300 m de CPU, cada uno de los seis Pods de aplicacion lleva
    sidecar, y con e2-medium el cluster no llega a programarlos todos.
  EOT
  type        = string
  default     = "e2-standard-2"
}

variable "node_count" {
  description = <<-EOT
    Numero de nodos del pool.
    Este es el renglon de coste dominante del laboratorio: tres e2-standard-2
    rondan los 0,20 USD/hora. El cluster esta pensado para levantarse, grabar
    la demostracion y destruirse el mismo dia.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.node_count >= 2
    error_message = "Con menos de 2 nodos no caben el plano de control de Istio y la aplicacion."
  }
}

variable "labels" {
  description = "Etiquetas aplicadas a los nodos"
  type        = map(string)
  default = {
    proyecto   = "otel-lab"
    curso      = "observabilidad"
    gestionado = "terraform"
  }
}
