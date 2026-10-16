# ════════════════════════════════════════════════════════════════════════════
# Salidas del despliegue en AWS
# ════════════════════════════════════════════════════════════════════════════

output "alb_url" {
  description = "URL pública de service-a a través del balanceador"
  value       = "http://${aws_lb.principal.dns_name}"
}

output "ecr_service_a" {
  description = "Repositorio ECR de service-a"
  value       = aws_ecr_repository.servicios["service-a"].repository_url
}

output "ecr_service_b" {
  description = "Repositorio ECR de service-b"
  value       = aws_ecr_repository.servicios["service-b"].repository_url
}

output "cluster_ecs" {
  description = "Nombre del cluster ECS"
  value       = aws_ecs_cluster.principal.name
}

output "service_b_dns" {
  description = "Nombre DNS interno de service-b (Cloud Map)"
  value       = "service-b.${aws_service_discovery_private_dns_namespace.interno.name}:8001"
}

output "rds_endpoint" {
  description = "Endpoint de PostgreSQL"
  value       = var.enable_rds ? aws_db_instance.postgres[0].address : "deshabilitado"
  sensitive   = true
}

output "consola_xray" {
  description = "Mapa de trazas en AWS X-Ray"
  value       = "https://${var.region}.console.aws.amazon.com/xray/home?region=${var.region}#/service-map"
}

output "consola_cloudwatch_logs" {
  description = "Logs de aplicación con trace_id en CloudWatch"
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#logsV2:log-groups/log-group/$252Fotel-lab$252Fservices"
}

output "comandos_publicacion" {
  description = "Secuencia para construir y publicar las imágenes antes del apply"
  value       = <<-EOT

    1. Autenticar Docker contra ECR:
       aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${split("/", aws_ecr_repository.servicios["service-a"].repository_url)[0]}

    2. Construir y publicar (desde la raíz del repositorio):
       docker build -t ${aws_ecr_repository.servicios["service-a"].repository_url}:${var.app_version} -f services/service-a/Dockerfile services/
       docker build -t ${aws_ecr_repository.servicios["service-b"].repository_url}:${var.app_version} -f services/service-b/Dockerfile services/

       docker push ${aws_ecr_repository.servicios["service-a"].repository_url}:${var.app_version}
       docker push ${aws_ecr_repository.servicios["service-b"].repository_url}:${var.app_version}

    3. Forzar un nuevo despliegue para que ECS tome las imágenes:
       aws ecs update-service --cluster ${aws_ecs_cluster.principal.name} --service service-b --force-new-deployment --region ${var.region}
       aws ecs update-service --cluster ${aws_ecs_cluster.principal.name} --service service-a --force-new-deployment --region ${var.region}

  EOT
}


output "cuenta_destino" {
  description = <<-EOT
    Cuenta y usuario con los que se esta desplegando.
    Conviene mirarlo antes de un apply: confirma que los recursos van a la
    cuenta del laboratorio y no a otra configurada en el mismo equipo.
  EOT
  value = {
    account_id = data.aws_caller_identity.actual.account_id
    arn        = data.aws_caller_identity.actual.arn
    perfil     = var.aws_profile
    region     = var.region
  }
}

# ── Modulo C: seguridad ─────────────────────────────────────────────────────
output "flow_logs_log_group" {
  description = "Grupo de CloudWatch Logs con los VPC Flow Logs de la VPC del laboratorio"
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "consultas_de_red" {
  description = "Consultas guardadas de Logs Insights para investigar trafico"
  value = [
    aws_cloudwatch_query_definition.quien_habla_con_quien.name,
    aws_cloudwatch_query_definition.salida_por_destino.name,
    aws_cloudwatch_query_definition.rechazos_por_puerto.name,
    aws_cloudwatch_query_definition.logs_por_trace.name,
  ]
}

output "topico_seguridad" {
  description = "Topico SNS al que llegan las alarmas de seguridad"
  value       = aws_sns_topic.seguridad.arn
}

output "recordatorio_apagado" {
  description = "Servicios de pago por uso que hay que desactivar a mano al terminar"
  value = var.habilitar_seguridad_avanzada ? join("\n", [
    "GuardDuty y Security Hub quedan ACTIVOS y cobran por volumen.",
    "Al terminar el laboratorio:",
    "  aws securityhub disable-security-hub --profile ${var.aws_profile}",
    "  aws guardduty delete-detector --detector-id <id> --profile ${var.aws_profile}",
  ]) : "Seguridad avanzada desactivada: no hay nada que apagar a mano."
}
