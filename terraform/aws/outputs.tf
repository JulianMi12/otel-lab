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
  value = <<-EOT

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
