# ════════════════════════════════════════════════════════════════════════════
# Despliegue del pipeline OTel en GCP — Cloud Run + Collector como sidecar
#
# Recursos creados:
#   - APIs necesarias del proyecto
#   - Artifact Registry para las imagenes de los servicios
#   - Service account con los permisos minimos de escritura de telemetria
#   - Secret Manager: password de la base de datos y config del Collector
#   - Cloud SQL PostgreSQL (opcional, es el unico recurso con costo continuo)
#   - Dos servicios de Cloud Run (service-a y service-b), cada uno con el
#     Collector corriendo como contenedor sidecar
#
# Uso:
#   terraform init
#   terraform plan  -var-file=terraform.tfvars
#   terraform apply -var-file=terraform.tfvars
# ════════════════════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  # Repositorio de imagenes al que apuntan ambos servicios de Cloud Run.
  registry = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo_name}"

  # Imagen oficial del Collector en su distribucion contrib: es la unica que
  # incluye los exporters de Google Cloud y Managed Prometheus.
  collector_image = "otel/opentelemetry-collector-contrib:0.103.0"

  common_env = {
    ENVIRONMENT    = var.environment
    GCP_PROJECT_ID = var.project_id
    CLOUD_PROVIDER = "gcp"
    APP_VERSION    = var.app_version
  }
}

# ════════════════════════════════════════════════════════════════════════════
# APIs del proyecto
# ════════════════════════════════════════════════════════════════════════════
resource "google_project_service" "requeridas" {
  for_each = toset([
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudtrace.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com",
    "compute.googleapis.com",
    "vpcaccess.googleapis.com",
  ])

  service = each.value

  # No se deshabilitan al destruir: otras cargas del proyecto podrian
  # depender de ellas y apagarlas romperia recursos ajenos al laboratorio.
  disable_on_destroy = false
}

# ════════════════════════════════════════════════════════════════════════════
# Artifact Registry
# ════════════════════════════════════════════════════════════════════════════
resource "google_artifact_registry_repository" "imagenes" {
  location      = var.region
  repository_id = var.artifact_repo_name
  description   = "Imagenes de los microservicios del laboratorio OTel"
  format        = "DOCKER"
  labels        = var.labels

  depends_on = [google_project_service.requeridas]
}

# ════════════════════════════════════════════════════════════════════════════
# Identidad y permisos
# ════════════════════════════════════════════════════════════════════════════
resource "google_service_account" "runtime" {
  account_id   = "otel-lab-runtime"
  display_name = "Runtime de los servicios del laboratorio OTel"
  description  = "Identidad de Cloud Run; el sidecar del Collector la usa para escribir telemetria"

  depends_on = [google_project_service.requeridas]
}

# Permisos minimos: solo escritura de las tres senales mas acceso a Cloud SQL.
# No se otorga ningun rol de lectura ni administrativo.
resource "google_project_iam_member" "runtime_roles" {
  for_each = toset([
    "roles/cloudtrace.agent",        # escribir trazas en Cloud Trace
    "roles/logging.logWriter",       # escribir logs en Cloud Logging
    "roles/monitoring.metricWriter", # escribir metricas en Cloud Monitoring
    "roles/cloudsql.client",         # conectarse a Cloud SQL
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# ════════════════════════════════════════════════════════════════════════════
# Secretos
# ════════════════════════════════════════════════════════════════════════════
resource "google_secret_manager_secret" "db_password" {
  secret_id = "otel-lab-db-password"
  labels    = var.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.requeridas]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = var.db_password
}

# La configuracion del Collector viaja como secreto y se monta como volumen en
# el sidecar. Esto permite cambiarla sin reconstruir ninguna imagen.
resource "google_secret_manager_secret" "collector_config" {
  secret_id = "otel-lab-collector-config"
  labels    = var.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.requeridas]
}

resource "google_secret_manager_secret_version" "collector_config" {
  secret      = google_secret_manager_secret.collector_config.id
  secret_data = file("${path.module}/../../otel-collector/collector-gcp.yaml")
}

resource "google_secret_manager_secret_iam_member" "acceso_runtime" {
  for_each = {
    db_password      = google_secret_manager_secret.db_password.secret_id
    collector_config = google_secret_manager_secret.collector_config.secret_id
  }

  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

# ════════════════════════════════════════════════════════════════════════════
# Base de datos
# ════════════════════════════════════════════════════════════════════════════
resource "google_sql_database_instance" "postgres" {
  count = var.enable_cloud_sql ? 1 : 0

  name             = "otel-lab-postgres"
  database_version = "POSTGRES_16"
  region           = var.region

  # Permite destruir la instancia con terraform destroy. En un entorno real
  # esto iria en true para evitar borrados accidentales.
  deletion_protection = false

  settings {
    tier              = var.db_tier
    availability_type = "ZONAL"
    disk_size         = 10
    disk_type         = "PD_HDD"
    user_labels       = var.labels

    ip_configuration {
      # Sin IP publica: Cloud Run se conecta por el socket de Cloud SQL,
      # que no expone la base de datos a internet.
      ipv4_enabled = true
    }

    backup_configuration {
      enabled = false
    }

    insights_config {
      query_insights_enabled = true
    }
  }

  depends_on = [google_project_service.requeridas]
}

resource "google_sql_database" "app" {
  count = var.enable_cloud_sql ? 1 : 0

  name     = var.db_name
  instance = google_sql_database_instance.postgres[0].name
}

resource "google_sql_user" "app" {
  count = var.enable_cloud_sql ? 1 : 0

  name     = var.db_user
  instance = google_sql_database_instance.postgres[0].name
  password = var.db_password
}

# ════════════════════════════════════════════════════════════════════════════
# Cloud Run — service-b (downstream, se despliega primero)
# ════════════════════════════════════════════════════════════════════════════
resource "google_cloud_run_v2_service" "service_b" {
  name     = "service-b"
  location = var.region
  labels   = var.labels

  # El trafico saliente de Cloud Run sale a internet salvo que se configure un
  # conector VPC, de modo que INGRESS_TRAFFIC_INTERNAL_ONLY haria que las
  # llamadas de service-a se vieran como externas y recibieran un 404.
  #
  # La proteccion no se pierde: service-b NO tiene binding para allUsers, asi
  # que solo la service account del laboratorio puede invocarlo y toda peticion
  # debe traer un token OIDC valido. El control es de IAM, no de red.
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.runtime.email
    labels          = var.labels

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    dynamic "volumes" {
      for_each = var.enable_cloud_sql ? [1] : []
      content {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [google_sql_database_instance.postgres[0].connection_name]
        }
      }
    }

    volumes {
      name = "collector-config"
      secret {
        secret = google_secret_manager_secret.collector_config.secret_id
        items {
          version = "latest"
          path    = "collector-config.yaml"
        }
      }
    }

    # ── Contenedor de la aplicacion ─────────────────────────────────────────
    containers {
      name  = "app"
      image = "${local.registry}/service-b:${var.app_version}"

      # El sidecar debe estar aceptando OTLP antes de que la app empiece a
      # exportar; si no, los primeros spans se pierden por conexion rechazada.
      depends_on = ["otel-collector"]

      ports {
        container_port = 8001
      }

      resources {
        limits = {
          cpu    = var.service_cpu
          memory = var.service_memory
        }

        # CPU siempre asignada, no solo durante las peticiones.
        #
        # Por defecto Cloud Run retira la CPU en cuanto una peticion termina.
        # El sidecar del Collector es un proceso de fondo que exporta por
        # lotes, asi que sin CPU entre peticiones nunca llega a enviar nada y
        # la telemetria se pierde al apagarse la instancia.
        cpu_idle = false
      }

      dynamic "env" {
        for_each = local.common_env
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name  = "OTEL_ENABLED"
        value = "true"
      }

      # localhost: el sidecar comparte el espacio de red del contenedor.
      env {
        name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
        value = "http://localhost:4317"
      }

      # Sin Cloud SQL la variable queda VACIA a proposito: el servicio detecta
      # la ausencia y usa el almacen en memoria de inmediato, sin gastar el
      # ciclo de reintentos de conexion contra un host inexistente, que podria
      # agotar el tiempo de arranque de Cloud Run.
      env {
        name  = "DATABASE_URL"
        value = var.enable_cloud_sql ? "postgresql://${var.db_user}:${var.db_password}@/${var.db_name}?host=/cloudsql/${google_sql_database_instance.postgres[0].connection_name}" : ""
      }

      env {
        name  = "DATASTORE"
        value = var.enable_cloud_sql ? "postgres" : "memoria"
      }

      dynamic "volume_mounts" {
        for_each = var.enable_cloud_sql ? [1] : []
        content {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }
      }

      startup_probe {
        http_get {
          path = "/health"
          port = 8001
        }
        initial_delay_seconds = 10
        period_seconds        = 5
        failure_threshold     = 10
      }
    }

    # ── Contenedor sidecar: OTel Collector ──────────────────────────────────
    containers {
      name  = "otel-collector"
      image = local.collector_image
      args  = ["--config=/etc/otel/collector-config.yaml"]

      resources {
        limits = {
          cpu    = "1"
          memory = var.collector_memory
        }

        cpu_idle = false
      }

      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }

      volume_mounts {
        name       = "collector-config"
        mount_path = "/etc/otel"
      }

      # Hace que depends_on sea efectivo: el contenedor no cuenta como listo
      # hasta que el receptor OTLP acepta conexiones en el puerto 4317.
      startup_probe {
        tcp_socket {
          port = 4317
        }
        initial_delay_seconds = 3
        period_seconds        = 3
        failure_threshold     = 10
        timeout_seconds       = 3
      }
    }
  }

  depends_on = [
    google_project_iam_member.runtime_roles,
    google_secret_manager_secret_version.collector_config,
  ]
}

# ════════════════════════════════════════════════════════════════════════════
# Cloud Run — service-a (punto de entrada publico)
# ════════════════════════════════════════════════════════════════════════════
resource "google_cloud_run_v2_service" "service_a" {
  name     = "service-a"
  location = var.region
  labels   = var.labels

  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.runtime.email
    labels          = var.labels

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    dynamic "volumes" {
      for_each = var.enable_cloud_sql ? [1] : []
      content {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [google_sql_database_instance.postgres[0].connection_name]
        }
      }
    }

    volumes {
      name = "collector-config"
      secret {
        secret = google_secret_manager_secret.collector_config.secret_id
        items {
          version = "latest"
          path    = "collector-config.yaml"
        }
      }
    }

    containers {
      name  = "app"
      image = "${local.registry}/service-a:${var.app_version}"

      # El sidecar debe estar aceptando OTLP antes de que la app empiece a
      # exportar; si no, los primeros spans se pierden por conexion rechazada.
      depends_on = ["otel-collector"]

      ports {
        container_port = 8000
      }

      resources {
        limits = {
          cpu    = var.service_cpu
          memory = var.service_memory
        }

        # CPU siempre asignada, no solo durante las peticiones.
        #
        # Por defecto Cloud Run retira la CPU en cuanto una peticion termina.
        # El sidecar del Collector es un proceso de fondo que exporta por
        # lotes, asi que sin CPU entre peticiones nunca llega a enviar nada y
        # la telemetria se pierde al apagarse la instancia.
        cpu_idle = false
      }

      dynamic "env" {
        for_each = local.common_env
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name  = "OTEL_ENABLED"
        value = "true"
      }

      env {
        name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
        value = "http://localhost:4317"
      }

      # La URL de service-b la resuelve Terraform: asi la dependencia entre
      # ambos servicios queda explicita en el grafo y no hay que copiarla a mano.
      env {
        name  = "SERVICE_B_URL"
        value = google_cloud_run_v2_service.service_b.uri
      }

      # Sin Cloud SQL la variable queda VACIA a proposito: el servicio detecta
      # la ausencia y usa el almacen en memoria de inmediato, sin gastar el
      # ciclo de reintentos de conexion contra un host inexistente, que podria
      # agotar el tiempo de arranque de Cloud Run.
      env {
        name  = "DATABASE_URL"
        value = var.enable_cloud_sql ? "postgresql://${var.db_user}:${var.db_password}@/${var.db_name}?host=/cloudsql/${google_sql_database_instance.postgres[0].connection_name}" : ""
      }

      env {
        name  = "DATASTORE"
        value = var.enable_cloud_sql ? "postgres" : "memoria"
      }

      dynamic "volume_mounts" {
        for_each = var.enable_cloud_sql ? [1] : []
        content {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }
      }

      startup_probe {
        http_get {
          path = "/health"
          port = 8000
        }
        initial_delay_seconds = 10
        period_seconds        = 5
        failure_threshold     = 10
      }
    }

    containers {
      name  = "otel-collector"
      image = local.collector_image
      args  = ["--config=/etc/otel/collector-config.yaml"]

      resources {
        limits = {
          cpu    = "1"
          memory = var.collector_memory
        }

        cpu_idle = false
      }

      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }

      volume_mounts {
        name       = "collector-config"
        mount_path = "/etc/otel"
      }

      # Hace que depends_on sea efectivo: el contenedor no cuenta como listo
      # hasta que el receptor OTLP acepta conexiones en el puerto 4317.
      startup_probe {
        tcp_socket {
          port = 4317
        }
        initial_delay_seconds = 3
        period_seconds        = 3
        failure_threshold     = 10
        timeout_seconds       = 3
      }
    }
  }

  depends_on = [
    google_project_iam_member.runtime_roles,
    google_secret_manager_secret_version.collector_config,
  ]
}

# ── Acceso publico a service-a ──────────────────────────────────────────────
# service-b NO recibe este binding: solo es alcanzable desde dentro del proyecto.
resource "google_cloud_run_v2_service_iam_member" "invocador_publico" {
  count = var.allow_public_access ? 1 : 0

  location = google_cloud_run_v2_service.service_a.location
  name     = google_cloud_run_v2_service.service_a.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# service-a necesita permiso explicito para invocar a service-b.
resource "google_cloud_run_v2_service_iam_member" "a_invoca_b" {
  location = google_cloud_run_v2_service.service_b.location
  name     = google_cloud_run_v2_service.service_b.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.runtime.email}"
}
