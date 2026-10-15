# Despliegue en GCP — guía paso a paso

Qué se necesita de Google Cloud para desplegar el pipeline, en el orden en que hace falta. Pensada para ejecutarse con una cuenta de universidad con créditos limitados.

**Resultado final:** `service-a` y `service-b` corriendo en Cloud Run, cada uno con el OTel Collector como contenedor sidecar, exportando trazas a Cloud Trace, logs a Cloud Logging y métricas a Managed Prometheus.

---

## 0. Resumen de lo que necesito de ti

| Dato | Para qué | Cómo obtenerlo |
|---|---|---|
| **Project ID** | Todos los recursos | `gcloud config get-value project` |
| **Región** | Cloud Run, Artifact Registry, Cloud SQL | Recomendado: `us-central1` |
| **Autenticación** | Terraform y Docker | `gcloud auth login` (interactivo, lo corres tú) |
| **Facturación activa** | Cloud Run y Artifact Registry la exigen | Consola → Facturación |

> El Project **ID** no es lo mismo que el nombre del proyecto. El ID suele llevar un sufijo numérico (`mi-proyecto-384715`) y es el que usa Terraform.

---

## 1. Prerrequisitos en tu máquina

```bash
gcloud --version      # Google Cloud SDK
terraform --version   # >= 1.5
docker --version
```

Si falta `gcloud`: https://cloud.google.com/sdk/docs/install
Si falta `terraform`: `winget install HashiCorp.Terraform`

---

## 2. Autenticación

Son **dos** autenticaciones distintas y hacen falta las dos:

```bash
# (a) Tu identidad, para los comandos de gcloud
gcloud auth login

# (b) Credenciales que usan las librerías — Terraform lee estas
gcloud auth application-default login
```

Fijar el proyecto activo:

```bash
gcloud config set project TU_PROJECT_ID
gcloud config get-value project     # verificar
```

---

## 3. Facturación

Cloud Run, Artifact Registry y Cloud SQL requieren una cuenta de facturación vinculada, aunque el consumo caiga dentro del nivel gratuito.

```bash
gcloud beta billing projects describe TU_PROJECT_ID
```

Debe aparecer `billingEnabled: true`. Si no:

```bash
gcloud beta billing accounts list
gcloud beta billing projects link TU_PROJECT_ID --billing-account=XXXXXX-XXXXXX-XXXXXX
```

---

## 4. APIs a habilitar

Terraform las habilita solo (recurso `google_project_service`), pero activarlas antes evita que el primer `apply` falle por propagación lenta:

```bash
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  cloudtrace.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  secretmanager.googleapis.com \
  sqladmin.googleapis.com \
  compute.googleapis.com
```

| API | Para qué sirve en este laboratorio |
|---|---|
| `run` | Ejecuta los dos microservicios y sus sidecars |
| `artifactregistry` | Aloja las imágenes Docker |
| `cloudtrace` | **Backend de trazas** (equivalente a Jaeger) |
| `logging` | **Backend de logs** (equivalente a Loki) |
| `monitoring` | **Backend de métricas** (Managed Prometheus) |
| `secretmanager` | Password de BD y configuración del Collector |
| `sqladmin` | Instancia PostgreSQL gestionada |
| `compute` | Red subyacente que usa Cloud Run |

Verificación:

```bash
gcloud services list --enabled --format="value(config.name)" | sort
```

---

## 5. Permisos de tu usuario

Para aplicar el Terraform completo necesitas, como mínimo:

| Rol | Por qué |
|---|---|
| `roles/run.admin` | Crear servicios de Cloud Run |
| `roles/artifactregistry.admin` | Crear el repositorio y publicar imágenes |
| `roles/iam.serviceAccountAdmin` | Crear la service account de runtime |
| `roles/iam.serviceAccountUser` | Asignar esa cuenta a Cloud Run |
| `roles/secretmanager.admin` | Crear los secretos |
| `roles/cloudsql.admin` | Crear la instancia PostgreSQL |
| `roles/resourcemanager.projectIamAdmin` | Conceder roles a la service account |

Si el proyecto es tuyo y tienes `roles/owner`, están todos cubiertos. Comprobación:

```bash
gcloud projects get-iam-policy TU_PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.members:$(gcloud config get-value account)" \
  --format="value(bindings.role)"
```

> Si es un proyecto compartido de la universidad y no eres owner, este es el punto donde conviene pedir los permisos antes de seguir.

---

## 6. Configurar Terraform

```bash
cd terraform/gcp
cp terraform.tfvars.example terraform.tfvars
```

Editar `terraform.tfvars`:

```hcl
project_id  = "tu-project-id-real"
db_password = "una-password-segura"
region      = "us-central1"

# Cloud SQL es el único recurso con costo por hora continuo.
# Ponlo en false si quieres conservar créditos (ver sección 10).
enable_cloud_sql = true
db_tier          = "db-f1-micro"

min_instances = 0    # escala a cero: no gasta en reposo
max_instances = 3    # techo de gasto ante una ráfaga
```

> `terraform.tfvars` está en `.gitignore`. **Nunca lo subas al repositorio.**

---

## 7. Publicar las imágenes

Cloud Run no construye imágenes: hay que publicarlas en Artifact Registry primero. El repositorio lo crea Terraform, así que es un `apply` en dos tiempos.

```bash
# 7.1 — Crear solo el registro
cd terraform/gcp
terraform init
terraform apply -target=google_artifact_registry_repository.imagenes

# 7.2 — Autenticar Docker contra el registro
gcloud auth configure-docker us-central1-docker.pkg.dev

# 7.3 — Construir y publicar (desde la RAÍZ del repositorio)
cd ../..
REG="us-central1-docker.pkg.dev/TU_PROJECT_ID/otel-lab"

docker build -t $REG/service-a:1.0.0 -f services/service-a/Dockerfile services/
docker build -t $REG/service-b:1.0.0 -f services/service-b/Dockerfile services/

docker push $REG/service-a:1.0.0
docker push $REG/service-b:1.0.0
```

> El contexto de build es `services/` (no `services/service-a/`), porque el Dockerfile copia el módulo compartido `common/telemetry.py`.

---

## 8. Desplegar

```bash
cd terraform/gcp
terraform plan     # revisar qué se va a crear
terraform apply
```

Al terminar imprime las URLs y enlaces directos a la consola:

```bash
terraform output service_a_url
terraform output consola_cloud_trace
terraform output consola_cloud_logging
```

---

## 9. Verificar el pipeline en la nube

```bash
URL=$(terraform output -raw service_a_url)

# Salud
curl $URL/health

# Flujo completo — devuelve el trace_id
curl $URL/order/ORD-0001
```

Con ese `trace_id`:

1. **Trazas** → Consola → Trace → Explorador. La traza debe mostrar spans de **ambos** servicios: es la prueba de que la propagación W3C funciona también en Cloud Run.
2. **Logs** → Consola → Logging. Filtro:
   ```
   logName="projects/TU_PROJECT_ID/logs/otel-lab"
   jsonPayload.trace_id="EL_TRACE_ID"
   ```
3. **Métricas** → Consola → Monitoring → Explorador de métricas. Buscar `prometheus/http_requests_total`.

Generar algo de tráfico para poblar las vistas:

```bash
for i in $(seq 1 50); do curl -s $URL/order/ORD-0001 > /dev/null; done
```

> **La base de datos arranca vacía.** Cloud SQL no ejecuta `scripts/init-db.sql` automáticamente. Para cargar el esquema:
> ```bash
> gcloud sql connect otel-lab-postgres --user=app --database=appdb < scripts/init-db.sql
> ```

---

## 10. Costos y cómo contenerlos

| Recurso | Costo aproximado | Nota |
|---|---|---|
| Cloud Run | ~0 USD en reposo | Escala a cero con `min_instances = 0` |
| Artifact Registry | ~0.10 USD/GB/mes | Las imágenes pesan ~400 MB |
| Cloud Trace | 2.5 M spans/mes gratis | El laboratorio no se acerca al límite |
| Cloud Logging | 50 GB/mes gratis | Idem |
| **Cloud SQL (db-f1-micro)** | **~8–10 USD/mes** | **El único costo continuo** |

Para conservar créditos: poner `enable_cloud_sql = false` y desplegar solo Cloud Run. El Collector y la propagación de trazas se demuestran igual; lo único que no funcionará son los endpoints que consultan la base de datos.

Otra opción es apagar la instancia entre sesiones de trabajo:

```bash
gcloud sql instances patch otel-lab-postgres --activation-policy NEVER   # apagar
gcloud sql instances patch otel-lab-postgres --activation-policy ALWAYS  # encender
```

---

## 11. Capturar evidencias

Con tráfico generado, capturar de la consola de GCP:

1. **Cloud Trace** — vista de cascada de una traza con spans de ambos servicios
2. **Cloud Trace** — lista de trazas con sus latencias
3. **Cloud Logging** — logs filtrados por `trace_id`
4. **Monitoring** — una métrica de la aplicación
5. **Cloud Run** — los dos servicios, mostrando los **dos contenedores por servicio** (app + sidecar)

La número 5 es la evidencia específica del criterio "Collector desplegado": demuestra el patrón sidecar funcionando en la nube.

Guardarlas en `docs/evidencias/gcp/`.

---

## 12. Destruir todo

```bash
cd terraform/gcp
terraform destroy
```

Conviene hacerlo al terminar: evita consumo de créditos por recursos olvidados.

Verificar que no quedó nada activo:

```bash
gcloud run services list
gcloud sql instances list
```

---

## Problemas frecuentes

**`Error 403: ... API has not been used in project`**
La API tarda en propagarse tras habilitarse. Esperar un minuto y repetir el `apply`.

**`denied: Permission "artifactregistry.repositories.uploadArtifacts" denied`**
Falta autenticar Docker: `gcloud auth configure-docker us-central1-docker.pkg.dev`.

**El servicio arranca y muere inmediatamente**
Casi siempre es la conexión a la base de datos. Revisar los logs del contenedor de aplicación:
```bash
gcloud run services logs read service-a --region us-central1 --limit 50
```

**No aparecen trazas en Cloud Trace**
Revisar los logs del sidecar, que van al mismo servicio con otro nombre de contenedor:
```bash
gcloud run services logs read service-a --region us-central1 --limit 50 | grep -i collector
```
La causa habitual es que falte el rol `roles/cloudtrace.agent` en la service account de runtime.

**`Quota exceeded` al crear Cloud SQL**
Las cuentas educativas suelen tener cuota limitada de instancias SQL. Desplegar con `enable_cloud_sql = false`.
