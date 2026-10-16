# ════════════════════════════════════════════════════════════════════════════
# Acceso de personas a la cuenta de AWS
#
# Raiz de Terraform separada de terraform/aws, y la razon es de CICLO DE VIDA.
#
# La infraestructura del laboratorio se levanta para una demostracion y se
# destruye despues: deja de cobrar en cuanto no se usa. El acceso de las
# personas no funciona asi. Que alguien pueda entrar a la cuenta no deberia
# depender de si hoy hay algo desplegado o no.
#
# Mientras ambas cosas vivieron en el mismo estado, un `terraform destroy` de
# la infraestructura se llevaba por delante a los tres usuarios y obligaba a
# repartir contrasenas nuevas la siguiente vez. Separarlas elimina ese
# acoplamiento: se puede destruir todo el laboratorio sin que nadie pierda su
# acceso, y se puede revocar un acceso sin tocar la infraestructura.
#
# Es el mismo criterio que separa terraform/observabilidad de los despliegues:
# las alertas describen COMO SE OBSERVA el sistema y sobreviven a cualquier
# despliegue concreto. Aqui, quien puede entrar sobrevive a lo que haya dentro.
#
# Nada de lo que crea este modulo tiene coste.
# ════════════════════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

# Se consulta para componer el enlace de acceso a la consola y para dejar
# constancia en los outputs de sobre que cuenta se esta actuando.
data "aws_caller_identity" "actual" {}
