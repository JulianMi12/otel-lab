# Módulo B — Detección de anomalías y correlación multi-señal

## El problema

Un umbral estático tiene que elegir entre dos formas de fallar, y no puede
evitar las dos:

- **Umbral bajo**: detecta todo, incluido el ruido normal del sistema. El
  equipo recibe tantas alertas que deja de leerlas.
- **Umbral alto**: no hace ruido, pero se pierde las degradaciones que no
  llegan al límite. El incidente lo descubre el cliente.

Este módulo ataca el problema con dos ideas, y las somete a una prueba
controlada para ver si funcionan.

## Las dos ideas

**1. Baseline móvil.** El límite no es un número fijo sino lo que el sistema
venía haciendo. Una latencia de 800 ms es normal bajo carga alta y anómala en
reposo; un umbral fijo no distingue los dos casos.

**2. Correlación multi-señal.** Una sola señal anómala no abre incidente.
Hacen falta dos a la vez —errores **y** latencia— sostenidas varios puntos
seguidos. El operador es **Y**, y ahí está todo el valor:

| Qué se observa | Qué significa | Acción |
|---|---|---|
| Solo latencia alta | El sistema está lento pero responde. Puede ser un pico de tráfico legítimo. | No se despierta a nadie |
| Solo errores | Unos pocos 5xx sin impacto en latencia: suele ser una dependencia opcional degradada. | No se despierta a nadie |
| Las dos a la vez | El sistema devuelve errores **y** tarda en hacerlo. | Incidente |

## El experimento

`aiops/escenario.sh` produce una ventana con ruido **y** con un incidente real,
para comprobar que el detector separa los dos. Cinco fases, 17 minutos:

| Fase | Duración | Qué ocurre | Qué debería pasar |
|---|---|---|---|
| Baseline | 7 min | Tráfico estable | Sin alertas |
| **Ruido** | 75 s | 700 ms de latencia inyectados en `service-b` | El umbral fijo dispara; la regla correlacionada **no** |
| Calma | 2 min | — | El baseline reabsorbe el pico |
| **Incidente** | 3 min | PostgreSQL detenido | La regla correlacionada abre incidente |
| Recuperación | 4 min | Base restaurada | El incidente se cierra solo |

### Por qué la base de datos y no más latencia

`service-a` degrada con elegancia ante un fallo de `service-b`: devuelve el
pedido sin inventario, con 200. Una latencia aguas abajo, por grande que sea,
**nunca** produce errores en `service-a`. El único fallo que mueve las dos
señales a la vez es el de la dependencia crítica — que es exactamente lo que
la regla busca.

## Resultados medidos

Ejecución del 16/10/2026, ventana 03:10:05Z → 03:27:37Z.

```
  enfoque                       alertas     útiles   sin acción
  ──────────────────────────────────────────────────────────────
  umbral fijo p99 > 500 ms            2          1            1
  umbral fijo p99 > 2000 ms           2          1            1
  baseline + correlación              1          1            0

  Reducción de ruido:   50 %
  Incidentes perdidos:  0
  Con trace_id:         1 de 1
```

El incidente detectado:

```
  Inicio        2026-10-16T03:21:05Z
  Duración      180 s
  p99           4.575 ms   (normal: 475 ms · SLO: 1.000 ms)
  error_rate    100 %      (normal: 0 %)
  trace_id      744735a7d612b133cf1c68614e27fe08
```

Y la traza que la alerta adjunta:

```
  GET /order/{order_id}    2.804 ms  ERROR  http=500
  order.process            2.802 ms  ERROR  HTTPException: 500: Database error
  fetch.order.db           2.801 ms  ERROR  HTTPException: 500: Database error
```

La alerta no dice "el p99 subió": entrega la petición concreta que falló, con
la causa en el tercer span.

## Lo que costó que funcionara

La primera ejecución detectó **cero** incidentes. Las cuatro causas, en orden
de descubrimiento, son más interesantes que el resultado final.

### 1. La serie de errores no existía

```promql
100 * sum(rate(http_requests_total{status="5xx"}[1m])) / clamp_min(...)
```

Mientras no hay ni un solo 5xx, la etiqueta `status="5xx"` no existe, `sum()`
no devuelve ninguna serie y **toda** la expresión queda vacía. El resultado:
la serie de errores solo tenía puntos *durante* el incidente, así que no había
historia previa con la que construir un baseline.

El arreglo es `or vector(0)` en el numerador.

### 2. El baseline aprendía que estar roto era normal

Con una ventana móvil de 5 minutos y un incidente de 3, el baseline absorbía
el propio incidente:

| Hora | p99 | baseline | límite | ¿anómalo? |
|---|---|---|---|---|
| 03:21:05 | 2.879 ms | 800 ms | 2.219 ms | sí |
| 03:22:35 | 2.485 ms | 1.539 ms | 3.662 ms | **no** |
| 03:23:20 | 2.485 ms | 1.763 ms | 3.923 ms | **no** |

El sistema dejaba de avisar justo mientras el incidente ocurría. El arreglo es
una **separación** de 12 puntos (3 min) entre el punto evaluado y su historia
—el equivalente exacto del `offset 5m` de las subqueries de PromQL.

El coste de ese parámetro es real y conviene nombrarlo: una degradación que
crezca más despacio que la separación se normaliza igualmente. Para eso está
la alerta de presupuesto de error, que mira horas en vez de minutos.

### 3. El exporter de métricas estaba fallando en silencio

Los tres servicios declaraban `http_requests_total` con descripciones
distintas (`"...atendidos por service-a"` / `"...por service-b"`). En
Prometheus el nombre de una métrica es **global**, así que la librería cliente
rechazaba la colección entera:

```
error gathering metrics: 6 error(s) occurred:
* collected metric http_requests_total ... has help "Total de requests HTTP
  atendidos por service-a" but should have "...por data-service"
```

Esto llevaba funcionando mal desde antes del módulo, y explicaba los huecos
sin causa aparente en las series. El arreglo: descripciones idénticas en los
tres servicios, sin mencionar a ninguno. Quién emite cada punto se sabe por la
etiqueta `service`, no por el texto de ayuda.

### 4. La alerta apuntaba al sitio equivocado

El enriquecimiento con `trace_id` falló tres veces seguidas, y cada fallo
enseñó algo:

| Intento | Criterio | Qué salió | Por qué está mal |
|---|---|---|---|
| 1.º | Exemplars de Prometheus | Nada | El SDK de Python 1.27 no implementa exemplars. Da igual que el Collector exponga OpenMetrics y Prometheus tenga `exemplar-storage`. |
| 2.º | Primera traza con error | Un error de DNS del borde de la ventana | No era el incidente |
| 3.º | Traza con el span raíz más largo | Una que devolvió **200** al cliente | El error estaba en un span interno que el fallback absorbió |
| 4.º | La más lenta **de las que fallaron para el cliente** | `fetch.order.db → Database error` | Correcto |

Más un quinto detalle: Jaeger devuelve las trazas **más recientes** de la
ventana, no una muestra repartida. Con `limit=20`, un incidente de tres
minutos devolvía solo los últimos segundos — que ya eran la recuperación.

La conclusión práctica: *una alerta que apunta al sitio equivocado es peor que
una que no apunta a ninguno*, porque dirige la investigación hacia una pista
falsa.

## Implementación en la nube

`terraform/observabilidad/aiops.tf` despliega cinco políticas en Cloud
Monitoring. Tres son la comparación del módulo y dos cubren huecos que la
correlación no ve:

| Política | Notifica | Qué detecta |
|---|---|---|
| `[referencia] p99 > 500 ms` | no | Cuántas veces habría interrumpido un umbral fijo estricto |
| `[referencia] p99 > 2000 ms` | no | Lo mismo con el umbral al que se llega tras silenciar el anterior |
| **Incidente correlacionado** | sí | error_rate sobre baseline + 2σ **Y** p99 sobre SLO, 3 min sostenidos |
| **Presupuesto de error** | sí | Degradación lenta que ninguna alerta puntual ve. Umbral de quemado 14,4× (SRE Workbook) |
| **Ausencia de señal** | sí | Que `service-a` deje de reportar |

La última nace de un hallazgo del propio laboratorio: al **pausar** el
contenedor de PostgreSQL (en vez de detenerlo), las peticiones se quedaron
colgadas indefinidamente y **no se registró ni un error ni una latencia** — el
bloque que publica las métricas nunca llegó a ejecutarse.

Un sistema que no responde tampoco emite señales. Sin esa política, el
incidente más grave posible es el único que pasa desapercibido.

### El baseline en PromQL

```promql
(error_rate)
>
(
  avg_over_time((error_rate)[1h:5m] offset 5m)
  + 2 * stddev_over_time((error_rate)[1h:5m] offset 5m)
  + 0.5
)
```

La subquery `[1h:5m]` evalúa la expresión cada 5 minutos durante la última
hora. El `offset 5m` es la separación: excluye el presente del baseline. El
`+ 0.5` es el piso de relevancia, que evita que un sistema muy estable alerte
por variaciones irrelevantes.

## Uso

```bash
# Contra el stack local
python aiops/detector.py --minutos 60 --comparar

# Sobre la ventana de un experimento de caos
python aiops/detector.py --desde 2026-10-15T18:40:00 --hasta 2026-10-15T18:50:00

# Baseline robusto (mediana y MAD en vez de media y sigma)
python aiops/detector.py --minutos 60 --robusto

# El escenario completo, de principio a fin
./aiops/escenario.sh
```

El detector devuelve código de salida 1 si hay incidentes abiertos, lo que lo
hace utilizable como puerta en un pipeline de CI.

## Parámetros y por qué valen lo que valen

| Parámetro | Valor | Razón |
|---|---|---|
| `PASO_S` | 15 s | La cadencia a la que el Collector exporta métricas |
| `VENTANA_BASELINE` | 20 puntos (5 min) | Suficiente para una media estable sin arrastrar el turno anterior |
| `SIGMAS` | 2,0 | Lo que pide el enunciado; cubre el 95 % de la distribución normal |
| `SEPARACION` | 12 puntos (3 min) | Impide que el incidente entre en su propio baseline |
| `DWELL` | 3 puntos (45 s) | Un pico de un punto puede ser un GC o un arranque en frío |
| `PISO_RELEVANCIA` | 50 ms / 0,5 pp | Evita alertar por variaciones sin relevancia operativa |
