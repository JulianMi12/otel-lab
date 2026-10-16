output "enlace_consola" {
  description = "URL de acceso a la consola de esta cuenta"
  value       = "https://${data.aws_caller_identity.actual.account_id}.signin.aws.amazon.com/console"
}

output "usuarios_creados" {
  description = "Quien tiene acceso y con que nivel"
  value       = var.usuarios
}

output "passwords_iniciales" {
  description = <<-EOT
    Passwords de un solo uso, por correo. Hay que cambiarlas en el primer
    acceso y entregarlas por un canal distinto al del enlace.
    Se leen con: terraform output -json passwords_iniciales
  EOT
  value       = { for k, v in aws_iam_user_login_profile.equipo : k => v.password }
  sensitive   = true
}
