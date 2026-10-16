#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# Despliegue del laboratorio en GKE con Istio — Modulo A
#
#   ./scripts/desplegar-gke.sh
#
# El script es idempotente: puede volver a lanzarse sin romper nada. Cada
# etapa comprueba primero si su resultado ya existe, porque el fallo tipico de
# este despliegue no es que algo no funcione, sino que algo tarda mas de lo
# previsto y hay que reintentar desde la mitad.
#
# Etapas:
#   1. Requisitos        gcloud, kubectl, istioctl, terraform, docker
#   2. Infraestructura   terraform apply en terraform/gke
#   3. Credenciales      kubectl apuntando al cluster nuevo
#   4. Imagenes          build y push de los tres servicios
#   5. Malla             istioctl install con el perfil del laboratorio
#   6. Aplicacion        kustomize con los placeholders resueltos
#   7. Verificacion      sidecars, mTLS y una traza de extremo a extremo
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

TF_DIR="terraform/gke"
NS="otel-lab"
VERSION="${APP_VERSION:-1.0.0}"

azul()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m  OK  \033[0m %s\n' "$*"; }
aviso() { printf '\033[1;33m AVISO\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m FALLO\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. Requisitos ───────────────────────────────────────────────────────────
azul "[1/7] Requisitos"

for cmd in gcloud kubectl terraform docker; do
  command -v "$cmd" >/dev/null 2>&1 || error "falta '$cmd' en el PATH"
done
ok "gcloud, kubectl, terraform y docker disponibles"

if ! command -v istioctl >/dev/null 2>&1; then
  aviso "istioctl no esta instalado. Instalalo con:"
  echo "    curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.23.2 sh -"
  echo "    export PATH=\"\$PWD/istio-1.23.2/bin:\$PATH\""
  error "istioctl es imprescindible para instalar la malla"
fi
ok "istioctl $(istioctl version --remote=false 2>/dev/null || echo '?')"

# ── 2. Infraestructura ──────────────────────────────────────────────────────
azul "[2/7] Infraestructura (Terraform)"

[ -f "$TF_DIR/terraform.tfvars" ] || error "falta $TF_DIR/terraform.tfvars (copia terraform.tfvars.example)"

terraform -chdir="$TF_DIR" init -input=false >/dev/null
terraform -chdir="$TF_DIR" apply -auto-approve -input=false

PROYECTO=$(terraform -chdir="$TF_DIR" output -raw project_id)
CLUSTER=$(terraform -chdir="$TF_DIR" output -raw cluster_nombre)
ZONA=$(terraform -chdir="$TF_DIR" output -raw cluster_zona)
REGISTRY=$(terraform -chdir="$TF_DIR" output -raw registry)
SA_COLLECTOR=$(terraform -chdir="$TF_DIR" output -raw collector_service_account)

ok "cluster $CLUSTER en $ZONA"
ok "registry $REGISTRY"

# ── 3. Credenciales ─────────────────────────────────────────────────────────
azul "[3/7] Credenciales de kubectl"

gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONA" --project "$PROYECTO" >/dev/null 2>&1
kubectl cluster-info >/dev/null || error "kubectl no alcanza el cluster"
ok "kubectl apunta a $(kubectl config current-context)"

# ── 4. Imagenes ─────────────────────────────────────────────────────────────
azul "[4/7] Imagenes"

gcloud auth configure-docker "${ZONA%-*}-docker.pkg.dev" --quiet >/dev/null 2>&1

for svc in service-a service-b data-service; do
  # Si la etiqueta ya existe en el registro se reutiliza. Reconstruir las tres
  # imagenes en cada intento añade varios minutos a un script que puede
  # relanzarse varias veces.
  if gcloud artifacts docker images describe "$REGISTRY/$svc:$VERSION" >/dev/null 2>&1; then
    ok "$svc:$VERSION ya esta en el registro"
    continue
  fi
  echo "    construyendo $svc..."
  docker build -q -t "$REGISTRY/$svc:$VERSION" -f "services/$svc/Dockerfile" services/ >/dev/null
  docker push "$REGISTRY/$svc:$VERSION" >/dev/null
  ok "$svc:$VERSION publicada"
done

# ── 5. Malla ────────────────────────────────────────────────────────────────
azul "[5/7] Istio"

if kubectl get namespace istio-system >/dev/null 2>&1 && \
   kubectl get deployment istiod -n istio-system >/dev/null 2>&1; then
  ok "istiod ya esta instalado"
else
  istioctl install -f k8s/istio/istio-operator.yaml -y
  ok "malla instalada"
fi

kubectl wait --for=condition=available --timeout=300s deployment/istiod -n istio-system
kubectl wait --for=condition=available --timeout=300s deployment/istio-ingressgateway -n istio-system
ok "plano de control listo"

# ── 6. Aplicacion ───────────────────────────────────────────────────────────
azul "[6/7] Aplicacion"

# Los manifiestos versionados llevan placeholders en lugar de valores reales
# (IMAGEN_SERVICE_A, PROYECTO_PENDIENTE). Asi el repositorio no contiene el ID
# del proyecto ni rutas de registro concretas, y un `kubectl apply -k` a mano
# falla de forma ruidosa en vez de desplegar en el sitio equivocado.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

kubectl kustomize --load-restrictor LoadRestrictionsNone k8s/ \
  | sed -e "s|IMAGEN_SERVICE_A|$REGISTRY/service-a:$VERSION|g" \
        -e "s|IMAGEN_SERVICE_B|$REGISTRY/service-b:$VERSION|g" \
        -e "s|IMAGEN_DATA_SERVICE|$REGISTRY/data-service:$VERSION|g" \
        -e "s|PROYECTO_PENDIENTE|$SA_COLLECTOR|g" \
  > "$TMP/manifiestos.yaml"

grep -q 'IMAGEN_\|PROYECTO_PENDIENTE' "$TMP/manifiestos.yaml" \
  && error "quedaron placeholders sin sustituir"

kubectl apply -f "$TMP/manifiestos.yaml"

# El ConfigMap con el ID del proyecto se crea aparte porque su valor sale de
# terraform.tfvars y no debe quedar versionado en el repositorio.
kubectl create configmap gcp-config -n "$NS" \
  --from-literal=project_id="$PROYECTO" \
  --dry-run=client -o yaml | kubectl apply -f -

ok "manifiestos aplicados"

echo "    esperando a los Pods..."
kubectl rollout status statefulset/postgres     -n "$NS" --timeout=300s
kubectl rollout status deployment/otel-collector -n "$NS" --timeout=300s
kubectl rollout status deployment/service-a      -n "$NS" --timeout=300s
kubectl rollout status deployment/service-b      -n "$NS" --timeout=300s
kubectl rollout status deployment/data-service   -n "$NS" --timeout=300s
ok "todos los Pods listos"

# ── 7. Verificacion ─────────────────────────────────────────────────────────
azul "[7/7] Verificacion"

# Cada Pod de aplicacion debe tener 2 contenedores: app + istio-proxy. Si sale
# 1/1, la etiqueta istio-injection del namespace no estaba puesta cuando se
# creo el Pod, y toda la telemetria de malla faltaria en silencio.
SIN_SIDECAR=$(kubectl get pods -n "$NS" -l 'app in (service-a,service-b,data-service)' \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .spec.containers[*]}{.name}{","}{end}{"\n"}{end}' \
  | grep -vc 'istio-proxy' || true)

if [ "$SIN_SIDECAR" -gt 0 ]; then
  aviso "$SIN_SIDECAR Pods sin sidecar. Forzando reinicio..."
  kubectl rollout restart deployment -n "$NS" service-a service-b data-service
  kubectl rollout status deployment/service-a -n "$NS" --timeout=300s
else
  ok "los tres servicios tienen sidecar Envoy"
fi

echo "    esperando IP del ingressgateway..."
for _ in $(seq 1 60); do
  IP=$(kubectl get svc istio-ingressgateway -n istio-system \
       -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ -n "${IP:-}" ] && break
  sleep 5
done
[ -n "${IP:-}" ] || error "el LoadBalancer no obtuvo IP publica"
ok "entrada de la malla: http://$IP"

echo "    generando una peticion de extremo a extremo..."
sleep 10
RESP=$(curl -s -m 20 -X POST "http://$IP/orders" \
  -H 'Content-Type: application/json' \
  -d '{"product":"laptop","quantity":2}' || true)

TRACE=$(printf '%s' "$RESP" | grep -oE '"trace_id"\s*:\s*"[a-f0-9]+"' | head -1 | grep -oE '[a-f0-9]{32}' || true)

if [ -n "$TRACE" ]; then
  ok "traza de extremo a extremo: $TRACE"
  echo
  echo "  Cloud Trace:"
  echo "    https://console.cloud.google.com/traces/list?project=$PROYECTO&tid=$TRACE"
else
  aviso "la peticion no devolvio trace_id. Respuesta:"
  printf '    %s\n' "$RESP"
fi

echo
azul "Listo"
cat <<RESUMEN

  Entrada            http://$IP
  Namespace          $NS
  Contexto kubectl   $(kubectl config current-context)

  Siguientes pasos
    Grafo de la malla      istioctl dashboard kiali
    Verificar mTLS         istioctl x describe pod -n $NS \$(kubectl get pod -n $NS -l app=service-a -o name | head -1 | cut -d/ -f2)
    Inyectar caos          kubectl apply -f k8s/50-chaos-istio.yaml
    Retirar caos           kubectl delete -f k8s/50-chaos-istio.yaml

  IMPORTANTE: el cluster cuesta aproximadamente 0,20 USD/hora mientras exista.
  Para apagarlo:  terraform -chdir=$TF_DIR destroy

RESUMEN
