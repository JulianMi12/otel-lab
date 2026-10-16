# ════════════════════════════════════════════════════════════════════════════
# GKE + Istio — plataforma del service mesh (Modulo A)
#
# Es una raiz de Terraform separada de terraform/gcp/ a proposito. Cloud Run y
# GKE son dos despliegues independientes del mismo codigo, y el objetivo del
# laboratorio es poder levantar y destruir el cluster (lo caro) sin tocar los
# servicios serverless (lo barato). Un unico estado para ambos obligaria a un
# `terraform apply` del conjunto cada vez.
#
# El reparto de responsabilidades es: Terraform crea el cluster, la identidad
# y los permisos; istioctl instala la malla; kustomize despliega la aplicacion.
# Terraform no gestiona objetos de Kubernetes porque el provider kubernetes
# necesitaria el cluster ya creado en el mismo plan, lo que produce el clasico
# fallo de configuracion de provider que depende de atributos de un recurso.
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

locals {
  registry = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo_name}"

  # Zonal, no regional. Un cluster regional replica el plano de control en
  # tres zonas y multiplica por tres el numero de nodos; para un laboratorio
  # que se destruye el mismo dia, eso es coste sin aprendizaje.
  zona = "${var.region}-a"
}

resource "google_project_service" "requeridas" {
  for_each = toset([
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudtrace.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "compute.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# ════════════════════════════════════════════════════════════════════════════
# Red
#
# VPC propia en lugar de la default: los VPC Flow Logs del Modulo C se
# habilitan por subred, y hacerlo sobre la red default registraria tambien
# trafico ajeno al laboratorio, inflando el coste de Cloud Logging.
# ════════════════════════════════════════════════════════════════════════════
resource "google_compute_network" "mesh" {
  name                    = "${var.project_name}-mesh-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.requeridas]
}

resource "google_compute_subnetwork" "nodos" {
  name          = "${var.project_name}-mesh-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.mesh.id

  # Rangos secundarios para Pods y Services. GKE en modo VPC-native los exige
  # y, a diferencia del modo basado en rutas, hace que cada Pod tenga una IP
  # enrutable en la VPC: sin eso los Flow Logs verian solo IPs de nodo y el
  # analisis de trafico este-oeste del Modulo C perderia toda resolucion.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "servicios"
    ip_cidr_range = var.services_cidr
  }

  # ── Modulo C: observabilidad de red ───────────────────────────────────────
  log_config {
    aggregation_interval = "INTERVAL_30_SEC"

    # Con muestreo 1.0 el volumen de logs del laboratorio supera la capa
    # gratuita de Cloud Logging en pocas horas; con 0.5 los patrones (quien
    # habla con quien, volumen, puertos) siguen siendo visibles.
    flow_sampling = var.flow_log_sampling
    metadata      = "INCLUDE_ALL_METADATA"
  }
}

# Router y NAT para que los nodos puedan bajar imagenes de Artifact Registry y
# el Collector alcanzar las APIs de Google.
resource "google_compute_router" "nat" {
  name    = "${var.project_name}-router"
  region  = var.region
  network = google_compute_network.mesh.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.project_name}-nat"
  router                             = google_compute_router.nat.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ════════════════════════════════════════════════════════════════════════════
# Cluster
# ════════════════════════════════════════════════════════════════════════════
resource "google_container_cluster" "mesh" {
  name     = "${var.project_name}-mesh"
  location = local.zona

  # GKE no permite crear un cluster sin node pool, pero el pool por defecto no
  # es configurable despues. El patron estandar es crearlo y borrarlo en el
  # mismo apply, dejando solo el pool gestionado de abajo.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.mesh.id
  subnetwork = google_compute_subnetwork.nodos.id

  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "servicios"
  }

  # Workload Identity: los Pods asumen una cuenta de servicio de GCP sin que
  # exista ninguna clave JSON en el cluster. Es lo que permite que el
  # Collector escriba en Cloud Trace sin credenciales montadas, y elimina de
  # raiz el riesgo de filtrar una clave en un manifiesto versionado.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Cloud Operations de GKE. Convive con el Collector sin solaparse: esto
  # recoge señales del PLANO DE CONTROL (apiserver, scheduler, kubelet), que
  # el Collector no ve; las de la aplicacion y la malla siguen yendo por OTLP.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]

    # Managed Prometheus es el destino del exporter googlemanagedprometheus
    # del Collector. Debe estar activo aqui o las metricas se rechazan.
    managed_prometheus {
      enabled = true
    }
  }

  # ── Modulo C: postura de seguridad ────────────────────────────────────────
  # Escanea los nodos contra las referencias de CIS y publica los hallazgos en
  # Security Command Center, que es la fuente del panel de seguridad.
  security_posture_config {
    mode               = "BASIC"
    vulnerability_mode = "VULNERABILITY_BASIC"
  }

  # El panel de red del Modulo C necesita saber que flujo corresponde a que
  # Pod y a que politica; sin dataplane avanzado los Flow Logs solo dan IPs.
  datapath_provider = "ADVANCED_DATAPATH"

  release_channel {
    channel = "REGULAR"
  }

  # Sin esto, un `terraform destroy` falla mientras queden LoadBalancers
  # creados por el ingressgateway de Istio.
  deletion_protection = false

  depends_on = [google_project_service.requeridas]
}

resource "google_container_node_pool" "principal" {
  name     = "principal"
  location = local.zona
  cluster  = google_container_cluster.mesh.name

  node_count = var.node_count

  node_config {
    machine_type = var.machine_type
    disk_size_gb = 50
    disk_type    = "pd-standard"

    service_account = google_service_account.nodos.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = var.labels
    tags   = ["otel-lab-nodo"]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# ════════════════════════════════════════════════════════════════════════════
# Identidades
# ════════════════════════════════════════════════════════════════════════════

# Identidad de los nodos. Deliberadamente minima: solo necesitan bajar
# imagenes y escribir sus propios logs. Todo lo demas lo hacen los Pods con su
# propia identidad via Workload Identity.
resource "google_service_account" "nodos" {
  account_id   = "${var.project_name}-gke-nodos"
  display_name = "Nodos del cluster del laboratorio"
}

resource "google_project_iam_member" "nodos_roles" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader",
    "roles/stackdriver.resourceMetadata.writer",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodos.email}"
}

# Identidad del Collector. Es la que acaba escribiendo las tres señales.
resource "google_service_account" "collector" {
  account_id   = "${var.project_name}-collector"
  display_name = "OpenTelemetry Collector del cluster"
  description  = "La asume la ServiceAccount otel-collector del namespace otel-lab"
}

resource "google_project_iam_member" "collector_roles" {
  for_each = toset([
    "roles/cloudtrace.agent",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.collector.email}"
}

# El enlace de Workload Identity. El `member` nombra una ServiceAccount de
# Kubernetes que todavia no existe cuando se aplica Terraform: es correcto, el
# binding es una politica de IAM sobre la cuenta de GCP y no valida el otro
# extremo. El vinculo se completa cuando kustomize crea la SA con la anotacion
# iam.gke.io/gcp-service-account.
resource "google_service_account_iam_member" "collector_workload_identity" {
  service_account_id = google_service_account.collector.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[otel-lab/otel-collector]"
}

# ════════════════════════════════════════════════════════════════════════════
# Modulo C — reglas de firewall observables
#
# Con logging activado, cada denegacion queda registrada en Cloud Logging y
# puede graficarse. Una regla de denegacion silenciosa protege igual de bien
# pero no genera la señal que permite detectar que alguien lo intento.
# ════════════════════════════════════════════════════════════════════════════
resource "google_compute_firewall" "denegar_salida_no_autorizada" {
  name      = "${var.project_name}-denegar-salida"
  network   = google_compute_network.mesh.name
  direction = "EGRESS"
  priority  = 65000

  deny {
    protocol = "tcp"
    ports    = ["22", "23", "3389"]
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["otel-lab-nodo"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "permitir_interno" {
  name      = "${var.project_name}-permitir-interno"
  network   = google_compute_network.mesh.name
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  source_ranges = [var.subnet_cidr, var.pods_cidr]
  target_tags   = ["otel-lab-nodo"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
