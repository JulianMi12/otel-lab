# ════════════════════════════════════════════════════════════════════════════
# Despliegue del pipeline OTel en AWS — ECS Fargate + Collector como sidecar
#
# Recursos creados:
#   - VPC con subredes publicas y privadas en dos zonas de disponibilidad
#   - Repositorios ECR para las imagenes de los microservicios
#   - Cluster ECS Fargate
#   - Dos servicios ECS, cada uno con dos contenedores: app + OTel Collector
#   - ALB publico delante de service-a
#   - Cloud Map (service discovery) para que service-a resuelva a service-b
#   - RDS PostgreSQL (opcional)
#   - Roles IAM con permisos minimos para X-Ray y CloudWatch
#
# Uso:
#   terraform init
#   terraform plan  -var-file=terraform.tfvars
#   terraform apply -var-file=terraform.tfvars
# ════════════════════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = var.tags
  }
}

# Identidad con la que se esta operando. Se expone como output para poder
# confirmar, antes de aplicar nada, que los recursos van a la cuenta correcta.
data "aws_caller_identity" "actual" {}

# La consulta de zonas se hace SOLO si no se nombran de forma explicita.
#
# El SCP de la organizacion deniega `ec2:DescribeAvailabilityZones` aunque
# permita el resto de EC2, de modo que este data source tumbaba el plan entero
# antes de crear nada. Nombrar las zonas en terraform.tfvars evita la llamada.
#
# No es solo un rodeo: fijar las zonas tambien hace el despliegue reproducible.
# AWS no garantiza que el orden que devuelve esta API sea estable, asi que un
# `apply` posterior podia mover las subredes de zona sin que nadie lo pidiera.
data "aws_availability_zones" "disponibles" {
  count = length(var.zonas) > 0 ? 0 : 1

  state = "available"
}

locals {
  nombre = var.project_name
  azs = length(var.zonas) > 0 ? var.zonas : slice(
    data.aws_availability_zones.disponibles[0].names, 0, var.az_count
  )

  # Distribucion imagen oficial del Collector de AWS. Incluye los exporters
  # awsxray, awsemf y awscloudwatchlogs preconfigurados y validados por AWS.
  collector_image = "public.ecr.aws/aws-observability/aws-otel-collector:v0.40.0"

  # Sin NAT Gateway las tasks van en subredes publicas con IP asignada.
  subredes_tasks = var.use_nat_gateway ? aws_subnet.privada[*].id : aws_subnet.publica[*].id
}

# ════════════════════════════════════════════════════════════════════════════
# RED
# ════════════════════════════════════════════════════════════════════════════
resource "aws_vpc" "principal" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.nombre}-vpc" }
}

resource "aws_internet_gateway" "principal" {
  vpc_id = aws_vpc.principal.id
  tags   = { Name = "${local.nombre}-igw" }
}

resource "aws_subnet" "publica" {
  count = var.az_count

  vpc_id                  = aws_vpc.principal.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.nombre}-publica-${local.azs[count.index]}" }
}

resource "aws_subnet" "privada" {
  count = var.use_nat_gateway ? var.az_count : 0

  vpc_id            = aws_vpc.principal.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 100)
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.nombre}-privada-${local.azs[count.index]}" }
}

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.principal.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.principal.id
  }

  tags = { Name = "${local.nombre}-rt-publica" }
}

resource "aws_route_table_association" "publica" {
  count = var.az_count

  subnet_id      = aws_subnet.publica[count.index].id
  route_table_id = aws_route_table.publica.id
}

# ── NAT Gateway (opcional) ──────────────────────────────────────────────────
resource "aws_eip" "nat" {
  count  = var.use_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${local.nombre}-nat-eip" }
}

resource "aws_nat_gateway" "principal" {
  count = var.use_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.publica[0].id
  tags          = { Name = "${local.nombre}-nat" }

  depends_on = [aws_internet_gateway.principal]
}

resource "aws_route_table" "privada" {
  count = var.use_nat_gateway ? 1 : 0

  vpc_id = aws_vpc.principal.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.principal[0].id
  }

  tags = { Name = "${local.nombre}-rt-privada" }
}

resource "aws_route_table_association" "privada" {
  count = var.use_nat_gateway ? var.az_count : 0

  subnet_id      = aws_subnet.privada[count.index].id
  route_table_id = aws_route_table.privada[0].id
}

# ════════════════════════════════════════════════════════════════════════════
# GRUPOS DE SEGURIDAD
# ════════════════════════════════════════════════════════════════════════════
resource "aws_security_group" "alb" {
  name        = "${local.nombre}-alb"
  description = "Entrada HTTP publica hacia el balanceador"
  vpc_id      = aws_vpc.principal.id

  ingress {
    description = "HTTP desde internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.nombre}-alb-sg" }
}

resource "aws_security_group" "tasks" {
  name        = "${local.nombre}-tasks"
  description = "Trafico de las tasks de ECS"
  vpc_id      = aws_vpc.principal.id

  ingress {
    description     = "service-a desde el ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # service-b y data-service solo aceptan trafico de otras tasks del mismo
  # grupo: no son alcanzables desde el ALB ni desde internet. Solo service-a
  # esta expuesto, que es el patron de un servicio de borde con dependencias
  # internas.
  ingress {
    description = "service-b desde otras tasks"
    from_port   = 8001
    to_port     = 8001
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "data-service desde otras tasks"
    from_port   = 8002
    to_port     = 8002
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.nombre}-tasks-sg" }
}

resource "aws_security_group" "rds" {
  count = var.enable_rds ? 1 : 0

  name        = "${local.nombre}-rds"
  description = "PostgreSQL accesible solo desde las tasks de ECS"
  vpc_id      = aws_vpc.principal.id

  ingress {
    description     = "PostgreSQL desde las tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.tasks.id]
  }

  tags = { Name = "${local.nombre}-rds-sg" }
}

# ════════════════════════════════════════════════════════════════════════════
# REGISTRO DE IMAGENES
# ════════════════════════════════════════════════════════════════════════════
resource "aws_ecr_repository" "servicios" {
  for_each = toset(["service-a", "service-b", "data-service"])

  name                 = "${local.nombre}/${each.value}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Conserva solo las ultimas 5 imagenes: ECR cobra por almacenamiento.
resource "aws_ecr_lifecycle_policy" "limpieza" {
  for_each = aws_ecr_repository.servicios

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Conservar solo las 5 imagenes mas recientes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ════════════════════════════════════════════════════════════════════════════
# IAM
# ════════════════════════════════════════════════════════════════════════════
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Rol de EJECUCION: lo usa el agente de ECS para traer la imagen y los secretos.
resource "aws_iam_role" "ejecucion" {
  name               = "${local.nombre}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "ejecucion_base" {
  role       = aws_iam_role.ejecucion.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ejecucion_secretos" {
  name = "${local.nombre}-leer-secretos"
  role = aws_iam_role.ejecucion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "ssm:GetParameters"]
      Resource = [aws_secretsmanager_secret.db_password.arn]
    }]
  })
}

# Rol de TAREA: lo asume el codigo en ejecucion, incluido el sidecar del
# Collector. Es el que autoriza a escribir en X-Ray y CloudWatch.
resource "aws_iam_role" "tarea" {
  name               = "${local.nombre}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "tarea_xray" {
  role       = aws_iam_role.tarea.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy_attachment" "tarea_cloudwatch" {
  role       = aws_iam_role.tarea.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# ════════════════════════════════════════════════════════════════════════════
# SECRETOS
# ════════════════════════════════════════════════════════════════════════════
resource "aws_secretsmanager_secret" "db_password" {
  name        = "${local.nombre}/db-password"
  description = "Password de PostgreSQL del laboratorio OTel"
  # Sin ventana de recuperacion: permite recrear el laboratorio de inmediato
  # sin chocar con un secreto del mismo nombre en estado de borrado pendiente.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password
}

# ════════════════════════════════════════════════════════════════════════════
# BASE DE DATOS
# ════════════════════════════════════════════════════════════════════════════
resource "aws_db_subnet_group" "principal" {
  count = var.enable_rds ? 1 : 0

  name       = "${local.nombre}-db-subnets"
  subnet_ids = aws_subnet.publica[*].id
}

resource "aws_db_instance" "postgres" {
  count = var.enable_rds ? 1 : 0

  identifier     = "${local.nombre}-postgres"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_user
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.principal[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  # Para un laboratorio: sin snapshot final y con borrado directo.
  skip_final_snapshot = true
  deletion_protection = false
  publicly_accessible = false

  backup_retention_period      = 0
  performance_insights_enabled = false

  tags = { Name = "${local.nombre}-postgres" }
}

# ════════════════════════════════════════════════════════════════════════════
# LOGS
# ════════════════════════════════════════════════════════════════════════════
resource "aws_cloudwatch_log_group" "servicios" {
  for_each = toset(["service-a", "service-b", "data-service"])

  name              = "/ecs/${local.nombre}/${each.value}"
  retention_in_days = var.log_retention_days
}

# Grupo al que el exporter awscloudwatchlogs del Collector envia los logs de
# aplicacion ya correlacionados con trace_id.
resource "aws_cloudwatch_log_group" "telemetria" {
  name              = "/otel-lab/services"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "metricas" {
  name              = "/otel-lab/metrics"
  retention_in_days = var.log_retention_days
}

# ════════════════════════════════════════════════════════════════════════════
# DESCUBRIMIENTO DE SERVICIOS
# ════════════════════════════════════════════════════════════════════════════
# Cloud Map da a service-b un nombre DNS estable dentro de la VPC. Sin esto,
# service-a tendria que conocer la IP de una task que cambia en cada despliegue.
resource "aws_service_discovery_private_dns_namespace" "interno" {
  name        = "${local.nombre}.local"
  description = "Namespace interno del laboratorio OTel"
  vpc         = aws_vpc.principal.id
}

resource "aws_service_discovery_service" "data_service" {
  name = "data-service"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.interno.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_service_discovery_service" "service_b" {
  name = "service-b"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.interno.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# ════════════════════════════════════════════════════════════════════════════
# CLUSTER ECS
# ════════════════════════════════════════════════════════════════════════════
resource "aws_ecs_cluster" "principal" {
  name = local.nombre

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "principal" {
  cluster_name       = aws_ecs_cluster.principal.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ════════════════════════════════════════════════════════════════════════════
# DEFINICIONES DE TAREA — app + Collector como sidecar
# ════════════════════════════════════════════════════════════════════════════
locals {
  db_host = var.enable_rds ? aws_db_instance.postgres[0].address : "localhost"
  db_url  = "postgresql://${var.db_user}:${var.db_password}@${local.db_host}:5432/${var.db_name}"

  # Config del Collector embebida como variable de entorno. ECS soporta pasar
  # la configuracion completa en AOT_CONFIG_CONTENT, lo que evita tener que
  # construir una imagen propia del Collector solo para incluir un archivo.
  collector_config = file("${path.module}/../../otel-collector/collector-aws.yaml")
}

resource "aws_ecs_task_definition" "service_b" {
  family                   = "${local.nombre}-service-b"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ejecucion.arn
  task_role_arn            = aws_iam_role.tarea.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${aws_ecr_repository.servicios["service-b"].repository_url}:${var.app_version}"
      essential = true

      portMappings = [{ containerPort = 8001, protocol = "tcp" }]

      cpu    = var.app_cpu
      memory = var.task_memory - var.collector_memory

      environment = [
        { name = "OTEL_ENABLED", value = "true" },
        # localhost: en red awsvpc los contenedores de la task comparten la
        # interfaz, por lo que el sidecar es alcanzable sin exponer puertos.
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4317" },
        { name = "DATABASE_URL", value = local.db_url },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "CLOUD_PROVIDER", value = "aws" },
        { name = "APP_VERSION", value = var.app_version },
        { name = "LATENCY_JITTER_MS", value = "25" },
      ]

      # El sidecar debe estar listo antes de que la app empiece a exportar,
      # o los primeros spans se pierden por conexion rechazada.
      dependsOn = [{ containerName = "otel-collector", condition = "START" }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.servicios["service-b"].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "app"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:8001/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    },
    {
      name      = "otel-collector"
      image     = local.collector_image
      essential = true

      cpu    = var.collector_cpu
      memory = var.collector_memory

      environment = [
        { name = "AWS_REGION", value = var.region },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "OTEL_SERVICE_NAME", value = "service-b" },
        { name = "AOT_CONFIG_CONTENT", value = local.collector_config },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.servicios["service-b"].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "collector"
        }
      }
    }
  ])
}

# ── data-service: tercer microservicio del laboratorio integrador ──────────
# Ejecuta las consultas analiticas y es el objetivo del experimento de caos
# del Modulo D (error rate del 10 %).
resource "aws_ecs_task_definition" "data_service" {
  family                   = "${local.nombre}-data-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ejecucion.arn
  task_role_arn            = aws_iam_role.tarea.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${aws_ecr_repository.servicios["data-service"].repository_url}:${var.app_version}"
      essential = true

      portMappings = [{ containerPort = 8002, protocol = "tcp" }]

      cpu    = var.app_cpu
      memory = var.task_memory - var.collector_memory

      environment = [
        { name = "OTEL_ENABLED", value = "true" },
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4317" },
        { name = "DATABASE_URL", value = local.db_url },
        { name = "DB_NAME", value = var.db_name },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "CLOUD_PROVIDER", value = "aws" },
        { name = "APP_VERSION", value = var.app_version },
        # Inyeccion de fallos del Modulo D. En reposo ambas van a cero; el
        # experimento se activa cambiando chaos_error_rate y forzando un
        # nuevo despliegue, sin tocar la imagen.
        { name = "CHAOS_LATENCY_MS", value = tostring(var.chaos_latency_ms) },
        { name = "CHAOS_ERROR_RATE", value = tostring(var.chaos_error_rate) },
      ]

      dependsOn = [{ containerName = "otel-collector", condition = "START" }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.servicios["data-service"].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "app"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:8002/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    },
    {
      name      = "otel-collector"
      image     = local.collector_image
      essential = true

      cpu    = var.collector_cpu
      memory = var.collector_memory

      environment = [
        { name = "AWS_REGION", value = var.region },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "OTEL_SERVICE_NAME", value = "data-service" },
        { name = "AOT_CONFIG_CONTENT", value = local.collector_config },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.servicios["data-service"].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "collector"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "data_service" {
  name            = "data-service"
  cluster         = aws_ecs_cluster.principal.id
  task_definition = aws_ecs_task_definition.data_service.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.subredes_tasks
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = !var.use_nat_gateway
  }

  service_registries {
    registry_arn = aws_service_discovery_service.data_service.arn
  }

  enable_execute_command = true
}

resource "aws_ecs_task_definition" "service_a" {
  family                   = "${local.nombre}-service-a"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ejecucion.arn
  task_role_arn            = aws_iam_role.tarea.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${aws_ecr_repository.servicios["service-a"].repository_url}:${var.app_version}"
      essential = true

      portMappings = [{ containerPort = 8000, protocol = "tcp" }]

      cpu    = var.app_cpu
      memory = var.task_memory - var.collector_memory

      environment = [
        { name = "OTEL_ENABLED", value = "true" },
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4317" },
        # Nombre DNS de Cloud Map: estable entre despliegues.
        { name = "SERVICE_B_URL", value = "http://service-b.${aws_service_discovery_private_dns_namespace.interno.name}:8001" },
        { name = "DATA_SERVICE_URL", value = "http://data-service.${aws_service_discovery_private_dns_namespace.interno.name}:8002" },
        { name = "DATABASE_URL", value = local.db_url },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "CLOUD_PROVIDER", value = "aws" },
        { name = "APP_VERSION", value = var.app_version },
      ]

      dependsOn = [{ containerName = "otel-collector", condition = "START" }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.servicios["service-a"].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "app"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    },
    {
      name      = "otel-collector"
      image     = local.collector_image
      essential = true

      cpu    = var.collector_cpu
      memory = var.collector_memory

      environment = [
        { name = "AWS_REGION", value = var.region },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "OTEL_SERVICE_NAME", value = "service-a" },
        { name = "AOT_CONFIG_CONTENT", value = local.collector_config },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.servicios["service-a"].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "collector"
        }
      }
    }
  ])
}

# ════════════════════════════════════════════════════════════════════════════
# BALANCEADOR
# ════════════════════════════════════════════════════════════════════════════
resource "aws_lb" "principal" {
  name               = "${local.nombre}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.publica[*].id

  enable_deletion_protection = false
}

resource "aws_lb_target_group" "service_a" {
  name        = "${local.nombre}-tg-a"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.principal.id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  # Las conexiones se cierran rapido al desregistrar: acelera los despliegues
  # del laboratorio, donde no hay trafico real que drenar con cuidado.
  deregistration_delay = 10
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.principal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service_a.arn
  }
}

# ════════════════════════════════════════════════════════════════════════════
# SERVICIOS ECS
# ════════════════════════════════════════════════════════════════════════════
resource "aws_ecs_service" "service_b" {
  name            = "service-b"
  cluster         = aws_ecs_cluster.principal.id
  task_definition = aws_ecs_task_definition.service_b.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.subredes_tasks
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = !var.use_nat_gateway
  }

  service_registries {
    registry_arn = aws_service_discovery_service.service_b.arn
  }

  enable_execute_command = true
}

resource "aws_ecs_service" "service_a" {
  name            = "service-a"
  cluster         = aws_ecs_cluster.principal.id
  task_definition = aws_ecs_task_definition.service_a.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.subredes_tasks
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = !var.use_nat_gateway
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.service_a.arn
    container_name   = "app"
    container_port   = 8000
  }

  # El listener debe existir antes del servicio o el registro en el target
  # group falla durante el primer despliegue.
  depends_on = [aws_lb_listener.http]

  enable_execute_command = true
}
