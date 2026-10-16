# ════════════════════════════════════════════════════════════════════════════
# Acceso de personas a la cuenta
#
# Usuarios de consola para el equipo y para quien evalua el trabajo. Se hace
# en AWS y no en GCP por una razon practica: GCP solo concede permisos a
# identidades de Google, y las direcciones @unisabana.edu.co no lo son, asi
# que la mitad del equipo no podia entrar. IAM no tiene esa restriccion.
#
# DOS NIVELES, Y LA DIFERENCIA IMPORTA
#
#   administrador  Para quienes construyen el laboratorio. Pueden crear y
#                  destruir infraestructura, que es lo que necesitan.
#
#   lectura        Para quien evalua. Puede inspeccionar cualquier recurso,
#                  ver metricas, logs y trazas, pero no modificar nada.
#
#   El nivel de lectura no es desconfianza: es que la cuenta tiene facturacion
#   activa, y un permiso de escritura permite generar gasto sin querer sobre
#   un presupuesto ajeno. Quien revisa no necesita nada de eso.
#
# ALTA DE UN USUARIO
#
#   En terraform.tfvars:
#     usuarios = {
#       "jhontero@unisabana.edu.co" = "administrador"
#       "mariaop@unisabana.edu.co"  = "lectura"
#     }
#
#   Las passwords iniciales se leen con:
#     terraform output -json passwords_iniciales
#
#   Hay que entregarlas por un canal distinto al del enlace de acceso. Todas
#   obligan a cambiarla en el primer inicio de sesion.
# ════════════════════════════════════════════════════════════════════════════

locals {
  # AWS admite el correo como nombre de usuario de IAM: el juego de caracteres
  # permitido incluye @ . - _ +. Usarlo evita tener que mantener un mapa entre
  # nombres cortos y personas, que es justo donde se pierde la trazabilidad de
  # quien tiene acceso a que.
  politicas_por_nivel = {
    administrador = "arn:aws:iam::aws:policy/AdministratorAccess"
    lectura       = "arn:aws:iam::aws:policy/ReadOnlyAccess"
  }

  usuarios_lectura = {
    for correo, nivel in var.usuarios : correo => nivel if nivel == "lectura"
  }
}

resource "aws_iam_user" "equipo" {
  for_each = var.usuarios

  name = each.key
  path = "/equipo/"

  # Sin force_destroy: si el usuario tiene claves de acceso creadas a mano,
  # `terraform destroy` debe fallar en lugar de borrarlas en silencio.
  tags = merge(var.tags, {
    Nivel    = each.value
    Proyecto = "otel-lab"
  })
}

resource "aws_iam_user_policy_attachment" "equipo" {
  for_each = var.usuarios

  user       = aws_iam_user.equipo[each.key].name
  policy_arn = local.politicas_por_nivel[each.value]
}

# ReadOnlyAccess SI permite leer secretos. Se deniega de forma explicita para
# el nivel de lectura: una denegacion siempre gana sobre un permiso, y no hay
# ninguna razon para que una revision necesite la password de la base de datos.
resource "aws_iam_user_policy" "lectura_sin_secretos" {
  for_each = local.usuarios_lectura

  name = "denegar-secretos"
  user = aws_iam_user.equipo[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Deny"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:BatchGetSecretValue",
        "kms:Decrypt",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_user_login_profile" "equipo" {
  for_each = var.usuarios

  user                    = aws_iam_user.equipo[each.key].name
  password_length         = 20
  password_reset_required = true

  # La password solo se genera una vez. Sin esto, cualquier `apply` posterior
  # la regeneraria e invalidaria la que ya se entrego.
  lifecycle {
    ignore_changes = [password_length, password_reset_required]
  }
}

# Politica de passwords de la CUENTA: afecta a todos los usuarios IAM, no solo
# a estos. Se crea solo si hay usuarios, para no dejar configuracion suelta en
# una cuenta sin nadie dentro.
resource "aws_iam_account_password_policy" "cuenta" {
  count = length(var.usuarios) > 0 ? 1 : 0

  minimum_password_length        = 14
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  max_password_age               = 180
}
