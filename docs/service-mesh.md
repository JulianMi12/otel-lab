# Módulo A — Service mesh con Istio sobre GKE

## Qué problema resuelve

Al terminar el laboratorio anterior, los dos servicios estaban instrumentados
con el SDK de OpenTelemetry. Eso da trazas, métricas y logs correlacionados,
pero tiene un límite incómodo: **toda la observabilidad depende de que alguien
haya escrito el código de instrumentación**. Un servicio que llega sin
instrumentar es invisible, y una política de reintentos vive dentro del
cliente HTTP de Python, donde cambiarla exige reconstruir la imagen.

El service mesh desplaza esa responsabilidad a la infraestructura. Cada Pod
recibe un proxy Envoy que:

- emite spans, métricas y logs de acceso sin tocar la aplicación;
- aplica timeouts, reintentos y circuit breakers declarados como manifiestos;
- cifra todo el tráfico interno con mTLS y adjunta la identidad del llamante.

El tercer microservicio (`data-service`) sirve para demostrarlo: está
instrumentado con el SDK **y** vive en la malla, así que permite comparar las
dos fuentes de telemetría sobre la misma petición.

## Arquitectura

```
                      Internet
                         │
              ┌──────────▼──────────┐
              │  istio-ingressgateway │  LoadBalancer  (Envoy)
              └──────────┬──────────┘
                         │  Gateway + VirtualService
                         │  timeout 10s, 2 reintentos
        ┌────────────────▼────────────────┐
        │  service-a        [app + Envoy] │  x2 réplicas
        └───────┬─────────────────┬───────┘
                │ mTLS STRICT     │ mTLS STRICT
                │ timeout 3s      │ timeout 2s
                │ 2 reintentos    │ 1 reintento
   ┌────────────▼──────┐   ┌──────▼─────────────────┐
   │ service-b         │   │ data-service           │  x2 cada uno
   │ [app + Envoy]     │   │ [app + Envoy]          │
   └────────┬──────────┘   └──────┬─────────────────┘
            │                     │
            └──────────┬──────────┘
                       │
              ┌────────▼────────┐        ┌──────────────────┐
              │  postgres       │        │ otel-collector   │
              │  (sin sidecar)  │        │ (sin sidecar)    │
              └─────────────────┘        └────────┬─────────┘
                                                  │
                                   Cloud Trace · Cloud Logging ·
                                   Managed Prometheus
```

Dos componentes quedan **fuera** de la malla a propósito:

| Componente | Por qué sin sidecar |
|---|---|
| `postgres` | Habla un protocolo binario que Envoy no inspecciona a L7. El proxy añadiría latencia sin aportar telemetría útil, y el arranque del sidecar compite con el `initContainer` de la base. |
| `otel-collector` | Si llevara sidecar, los spans de ese sidecar se exportarían a través del propio Collector que los genera. Es un bucle de telemetría que infla el tráfico y ensucia el grafo de servicios. |

## Las dos fuentes de telemetría

La petición `POST /orders` genera spans desde dos sitios distintos, y ambos
comparten el mismo `trace_id` porque Envoy propaga el mismo `traceparent` W3C
que ya usaba el SDK.

| | Span del SDK | Span de Envoy |
|---|---|---|
| **Quién lo emite** | El código de la aplicación | El sidecar |
| **Qué mide** | Tiempo dentro del proceso | Tiempo visto desde la red |
| **Atributos** | Semánticos de dominio (`db.statement`, `order.id`) | De transporte (`response_flags`, `upstream_cluster`) |
| **Si el servicio no está instrumentado** | No existe | Sigue existiendo |

La resta entre ambos es el coste de red más el encolado del proxy: un dato que
la instrumentación de aplicación por sí sola no puede dar.

## Resiliencia derivada de los experimentos de caos

Los valores de `42-istio-resiliencia.yaml` no son genéricos. Salen de los tres
experimentos del Game Day:

| Hallazgo del experimento | Política que lo corrige |
|---|---|
| **E1**: un timeout de 5 s convertía 200 ms de degradación en un p99 de 7.475 ms, porque la llamada lenta retenía el worker hasta agotar el plazo. | `timeout: 3s` hacia `service-b`, por debajo del plazo de 10 s del borde, con margen para un reintento completo. |
| **E1**: la cola de peticiones crecía sin límite mientras `service-b` estaba degradado. | `http1MaxPendingRequests: 32` — la petición 33 se rechaza de inmediato en vez de encolarse. |
| **E3**: ningún reintento arregla un error determinista de base de datos; solo multiplican la carga sobre un servicio ya caído. | `retryOn` hacia `data-service` excluye `5xx`: solo reintenta `reset` y `connect-failure`, que sí son transitorios. |
| La degradación de una instancia arrastraba a las demás. | `outlierDetection` expulsa la instancia tras 5 errores consecutivos, con `maxEjectionPercent: 50` para que una degradación parcial no se convierta en caída total. |

La diferencia operativa frente a Cloud Run es que allí estos plazos estaban
escritos en el cliente HTTP de Python. Aquí se cambian con un `kubectl apply`,
sin reconstruir imagen, y el cambio queda versionado como manifiesto.

## Seguridad de la malla (base del Módulo C)

`41-istio-seguridad.yaml` establece tres capas:

1. **`PeerAuthentication` en `STRICT`** — todo el tráfico entre Pods va
   cifrado. Un Pod sin certificado emitido por Istio no puede hablar con nadie.

2. **`AuthorizationPolicy` vacía (`deny all`)** — sin ella, `STRICT` solo
   garantiza que el tráfico va cifrado, no que el llamante tenga derecho a
   llamar: cualquier Pod con sidecar del clúster podría invocar `data-service`.

3. **Permisos explícitos por identidad SPIFFE, método y ruta** — `service-b`
   solo acepta a `service-a`, y solo en `GET /inventory/*`. Si un atacante
   tomara un Pod de `service-b`, no podría pivotar hacia `data-service`: la
   malla rechaza la llamada en el Envoy de destino, antes de que llegue al
   proceso.

Cada denegación aparece en los logs de acceso con el `source_principal` del
llamante y el `trace_id` de la petición, de modo que un 403 se puede abrir
hasta la traza que lo provocó.

## Caos a nivel de malla (Módulo D)

`50-chaos-istio.yaml` **no se aplica con `kubectl apply -k`**. Se aplica a mano
durante la ventana del experimento y se retira después.

Coexiste con el caos de aplicación (`CHAOS_LATENCY_MS` / `CHAOS_ERROR_RATE` en
`data-service`) porque responden a preguntas distintas:

| | Caos en la aplicación | Caos en la malla |
|---|---|---|
| **Pregunta** | ¿Qué pasa si el proceso se degrada? | ¿Qué pasa si la red entre dos servicios se degrada? |
| **Qué prueba** | Timeouts del cliente, manejo de excepciones, degradación elegante | Infraestructura: el fallo ocurre en el Envoy, el proceso de destino ni se entera |
| **Radio de impacto** | Toda la instancia | Solo el tráfico con la cabecera `x-chaos` |

Lo segundo es lo que permite reproducir una partición de red sin tocar el
kernel — precisamente lo que no se pudo hacer en WSL2 por la ausencia del
módulo `sch_netem`.

```bash
# Activar E1 (200 ms de latencia hacia service-b)
kubectl apply -f k8s/50-chaos-istio.yaml
curl -H 'x-chaos: e1' -X POST http://$IP/orders -d '{"product":"laptop","quantity":1}'

# Retirar
kubectl delete -f k8s/50-chaos-istio.yaml
```

## Despliegue

```bash
# Requisito: istioctl en el PATH
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.23.2 sh -
export PATH="$PWD/istio-1.23.2/bin:$PATH"

# Todo el despliegue, de extremo a extremo
./scripts/desplegar-gke.sh
```

El script es idempotente: comprueba si cada etapa ya está hecha antes de
repetirla, porque el fallo típico de este despliegue no es que algo no
funcione, sino que algo tarda más de lo previsto y hay que reintentar desde la
mitad.

### Coste

El clúster es el renglón dominante del laboratorio: **3 × e2-standard-2 ≈ 0,20
USD/hora**, más el LoadBalancer del ingressgateway. Está pensado para
levantarse, grabar la demostración y destruirse el mismo día.

```bash
terraform -chdir=terraform/gke destroy
```

## Verificación

```bash
# ¿Los tres servicios tienen sidecar? Debe salir 2/2 en cada Pod.
kubectl get pods -n otel-lab

# ¿El tráfico va realmente por mTLS?
istioctl x describe pod -n otel-lab $(kubectl get pod -n otel-lab -l app=service-a -o name | head -1 | cut -d/ -f2)

# Grafo de servicios y porcentajes de error
istioctl dashboard kiali

# Configuración efectiva de un Envoy (útil cuando una política no surte efecto)
istioctl proxy-config route -n otel-lab deploy/service-a
```

## Los dos despliegues conviven

| | Cloud Run (`terraform/gcp`) | GKE + Istio (`terraform/gke`) | ECS Fargate (`terraform/aws`) |
|---|---|---|---|
| Collector | Sidecar por revisión | Deployment único | Sidecar por task |
| Identidad entre servicios | Token OIDC del metadata server | Certificado mTLS de Istio | Security group + service discovery |
| Resiliencia | Código del cliente HTTP | Manifiestos de Istio | Código del cliente HTTP |
| Coste en reposo | ~0 | ~0,20 USD/h | ~0,05 USD/h |

Es la misma imagen de contenedor en los tres. `service-a` detecta en qué
entorno corre por el esquema de la URL del destino: si es `https://` pide un
token OIDC (Cloud Run); si es `http://` no lo pide, porque dentro de la malla
la identidad la establece el certificado, no la cabecera.
