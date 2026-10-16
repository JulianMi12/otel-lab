# Despliegue en AWS — guía paso a paso

Qué necesita AWS para desplegar el pipeline, en el orden en que hace falta.
Pensada para una cuenta nueva en capa gratuita.

**Resultado final:** `service-a`, `service-b` y `data-service` en ECS Fargate, cada uno con el OTel Collector como sidecar, exportando trazas a X-Ray, logs a CloudWatch Logs y métricas a CloudWatch EMF; más VPC Flow Logs y Security Hub para el Módulo C.

---

## ⚠️ Antes de nada: AWS cobra distinto a GCP

En GCP el riesgo era un único recurso (Cloud SQL). **En AWS hay varios servicios que cobran por hora aunque no los uses**, y la factura aparece al final del mes. Los tres que más sorpresas dan:

| Recurso | Costo si se olvida | ¿Lo usamos? |
|---|---|---|
| **NAT Gateway** | ~32 USD/mes **por zona** | **NO** — `use_nat_gateway = false` |
| **Application Load Balancer** | ~16 USD/mes | Sí, pero free tier cubre 750 h el primer año |
| **Security Hub** | gratis 30 días, luego por comprobación | Sí, Módulo C — **desactivar al terminar** |
| **RDS db.t4g.micro** | gratis 750 h/mes el primer año | Sí |
| **ECS Fargate** | ~0,04 USD/hora por tarea | Sí, sin free tier |

Con todo encendido unas horas el gasto son **céntimos**. Olvidado un mes, pueden ser **50-80 USD**. Por eso el paso 3 (presupuesto con alerta) no es opcional.

---

## 1. Crear la cuenta

1. Ve a [aws.amazon.com](https://aws.amazon.com) → **Crear una cuenta de AWS**
2. Necesitarás: correo, **tarjeta de crédito** (hace un cargo de verificación de ~1 USD que se devuelve) y un teléfono para el SMS
3. Elige el plan de soporte **Basic (gratuito)**
4. La activación tarda unos minutos; a veces hasta 24 h

> Usa un correo que no sea el de la universidad si quieres conservar la cuenta después del curso.

---

## 2. Proteger la cuenta raíz

La cuenta con la que te registras (*root*) tiene poder absoluto y **no debe usarse para trabajar**.

1. Inicia sesión → busca **IAM** → **Habilitar MFA** en la cuenta raíz
2. Usa Google Authenticator o similar

Esto es importante de verdad: una cuenta raíz comprometida sin MFA es el escenario clásico de factura de miles de dólares por minado de criptomonedas.

---

## 3. Presupuesto con alerta (no te lo saltes)

```
Consola → Billing and Cost Management → Budgets → Create budget
```

- Tipo: **Cost budget**
- Periodo: **Monthly**
- Importe: **5 USD**
- Alertas: al **50 %**, **80 %** y **100 %** del importe, a tu correo

Con este laboratorio no deberías acercarte a 5 USD. Cualquier aviso significa que algo quedó encendido.

Actívalo también:

```
Billing → Billing preferences → ✓ Receive Free Tier Usage Alerts
```

---

## 4. Usuario IAM para Terraform

Terraform **no** debe usar la cuenta raíz.

```
IAM → Users → Create user
```

- Nombre: `terraform-otel-lab`
- **No** marques acceso a consola (solo programático)
- Permisos: **Attach policies directly** → `AdministratorAccess`

> `AdministratorAccess` es excesivo para producción, pero este laboratorio crea VPC, ECS, RDS, IAM y Security Hub: acotar los permisos exigiría una política muy larga. Al terminar el curso, borra el usuario.

Después de crearlo:

```
Usuario → Security credentials → Create access key
→ Caso de uso: Command Line Interface (CLI)
```

Copia el **Access key ID** y el **Secret access key**. El secreto **solo se muestra una vez**.

---

## 5. Instalar y configurar el CLI

```powershell
winget install --id Amazon.AWSCLI -e
```

Cierra y reabre la terminal, luego:

```powershell
aws configure
```

Te pedirá cuatro datos:

```
AWS Access Key ID     : (el del paso 4)
AWS Secret Access Key : (el del paso 4)
Default region name   : us-east-1
Default output format : json
```

Comprueba que funciona:

```powershell
aws sts get-caller-identity
```

Debe devolver tu `Account` y el ARN del usuario `terraform-otel-lab`.

---

## 6. Qué desplegaremos y por qué

| Módulo | Recurso AWS | Para qué |
|---|---|---|
| **A** | ECS Fargate × 3 servicios | `service-a`, `service-b`, `data-service` |
| **A** | RDS PostgreSQL `db.t4g.micro` | Base de datos del `data-service` |
| **A** | App Mesh *(o documentado)* | Observabilidad L7 |
| **A** | X-Ray · CloudWatch Logs · EMF | Las tres señales |
| **C** | VPC Flow Logs → CloudWatch | Tráfico entre servicios |
| **C** | Security Hub | Golden Signals de seguridad |

El Terraform de todo esto ya está escrito en `terraform/aws/` desde el laboratorio 2.2; para el integrador se amplía con `data-service`, Flow Logs y Security Hub.

---

## 7. Desplegar

```powershell
cd terraform\aws
copy terraform.tfvars.example terraform.tfvars
```

Edita `terraform.tfvars`:

```hcl
region       = "us-east-1"
db_password  = "una-password-segura"

# El NAT Gateway es el recurso más caro de AWS (~32 USD/mes).
# Con false, las tareas van en subredes públicas con IP asignada.
use_nat_gateway = false

enable_rds        = true
db_instance_class = "db.t4g.micro"   # capa gratuita 12 meses
desired_count     = 1
```

Luego:

```powershell
terraform init
terraform plan        # revisa SIEMPRE qué va a crear
terraform apply
```

Igual que en GCP, es un `apply` en dos tiempos: primero se crea ECR, después se publican las imágenes y por último se despliegan los servicios. El output `comandos_publicacion` imprime la secuencia exacta.

---

## 8. Verificar

```powershell
terraform output alb_url
curl (terraform output -raw alb_url)/health
```

Y en la consola:

- **X-Ray** → Service map: debe mostrar los tres servicios conectados
- **CloudWatch** → Log groups → `/otel-lab/services`
- **VPC** → Flow Logs
- **Security Hub** → Findings

---

## 9. ⚠️ Destruir al terminar

**Este es el paso que de verdad importa en AWS.**

```powershell
cd terraform\aws
terraform destroy
```

Security Hub **no lo gestiona Terraform** si lo activaste a mano:

```powershell
aws securityhub disable-security-hub --region us-east-1
```

Comprueba que no queda nada vivo:

```powershell
aws ecs list-clusters
aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier"
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"
aws ec2 describe-nat-gateways --query "NatGateways[?State=='available'].NatGatewayId"
```

Las cuatro deben devolver listas vacías. Revisa además **Billing → Bills** unos días después: AWS factura con retraso.

---

## Problemas frecuentes

**`UnauthorizedOperation` o `AccessDenied`**
El usuario IAM no tiene `AdministratorAccess`, o `aws configure` está usando otro perfil. Comprueba con `aws sts get-caller-identity`.

**`InvalidClientTokenId`**
Las credenciales son incorrectas o la cuenta aún no está activada del todo. Si acabas de registrarte, espera y reintenta.

**RDS tarda 10-15 minutos en crearse**
Es normal. Terraform espera; no interrumpas el `apply`.

**`Error: creating ELBv2 Load Balancer: ValidationError: At least two subnets`**
El ALB exige subredes en dos zonas. La variable `az_count` ya está en 2; no la bajes.

**La factura muestra cargos inesperados**
Lo más probable es un NAT Gateway, un ALB huérfano o Security Hub pasados los 30 días. Revisa `Billing → Cost Explorer` agrupando por servicio.

---

## Resumen: qué necesito de ti

Cuando termines, pásame o comprueba:

1. `aws sts get-caller-identity` devuelve tu cuenta ✓
2. El presupuesto de 5 USD con alerta está creado ✓
3. La región que prefieras (por defecto `us-east-1`)

Con eso yo me encargo del resto: Terraform, despliegue, verificación y captura de evidencias.
