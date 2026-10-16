# Módulo E — Autoevaluación de madurez y hoja de ruta

> **Nota sobre los dominios.** El enunciado pide evaluar ocho dominios del
> *Observability Foundation Blueprint* sin enumerarlos. Los ocho que siguen
> cubren el temario de los tres laboratorios; si la rúbrica usa otros nombres,
> el contenido de cada fila es trasladable.

## Cómo se puntúa

La tentación de una autoevaluación es puntuarse por lo que uno *ha construido*.
Aquí se puntúa por lo que el sistema **demostró** bajo observación, que no es lo
mismo: cada nivel exige una evidencia concreta, y varias de las evidencias de
este laboratorio son fallos que el propio pipeline destapó.

| Nivel | Nombre | Qué hace falta para alcanzarlo |
|---|---|---|
| 1 | Inicial | La capacidad existe de forma manual o accidental |
| 2 | Repetible | Está escrita y alguien puede repetirla |
| 3 | Definido | Es código versionado, se aplica igual en todos los entornos |
| 4 | Gestionado | Se mide, y la medición ha cambiado alguna decisión |
| 5 | Optimizado | Se corrige sola o avisa antes de que el problema ocurra |

Se distingue además entre **definido como código** y **verificado en
ejecución**. Un manifiesto que nunca se aplicó no es evidencia de nada, y
tratarlo como si lo fuera es la forma más común de inflar una autoevaluación.

---

## Resultado por dominio

| # | Dominio | Nivel | Verificado en ejecución |
|---|---|:---:|:---:|
| 1 | Instrumentación y cobertura de señales | **4** | sí |
| 2 | Pipeline de telemetría | **4** | sí |
| 3 | Correlación entre señales | **3** | parcial |
| 4 | SLO y presupuesto de error | **3** | sí |
| 5 | Alertado y respuesta | **3** | parcial |
| 6 | Observabilidad de infraestructura y red | **2** | no |
| 7 | Seguridad | **2** | no |
| 8 | Resiliencia y cultura de experimentación | **4** | sí |

**Media: 3,1 sobre 5.** El perfil es deliberadamente desigual: los dominios
que el laboratorio ejecutó de verdad están en 4, y los que solo existen como
código están en 2. Subir esos dos a 3 no requiere escribir nada más — requiere
desplegar y comprobar.

---

### 1. Instrumentación y cobertura de señales — nivel 4

**Evidencia.** Tres servicios (`service-a`, `service-b`, `data-service`)
emiten las tres señales desde un bootstrap común (`services/common/telemetry.py`).
Los spans de base de datos siguen las DB Semantic Conventions
(`db.system`, `db.operation`, `db.statement`, `db.rows_affected`), con el
parámetro como marcador y no interpolado, de modo que el atributo nunca lleva
datos de usuario.

**Por qué 4 y no 3.** La medición cambió decisiones, dos veces:

- El benchmark de sobrecarga con `OTEL_ENABLED=false` mostró que el coste de
  la instrumentación **cambia de forma** según la CPU disponible, no que sea
  un porcentaje fijo. Eso llevó a subir los límites de Docker en vez de a
  recortar instrumentación.
- Los *buckets* de los histogramas estaban en milisegundos mientras el código
  registraba segundos, y el p99 salía clavado en ~4.950 ms. Se corrigió con
  Views explícitas.

**Qué falta para el 5.** No hay instrumentación de frontend (RUM) ni perfilado
continuo. La cobertura se da por buena porque los servicios son tres; en un
sistema real haría falta un control automático que detectara servicios sin
instrumentar.

---

### 2. Pipeline de telemetría — nivel 4

**Evidencia.** Un Collector con la cadena completa
`memory_limiter → k8sattributes → resourcedetection → resource → filter →
batch`, con cuatro configuraciones (`local`, `gcp`, `gke`, `aws`) que comparten
estructura y difieren solo en los exporters.

**Por qué 4.** Tres fallos reales detectados y corregidos por medición:

| Fallo | Cómo se manifestó |
|---|---|
| Métricas contadas dos veces (push + scrape) | Las consultas del panel filtran `source="collector"` |
| El exporter `googlecloud` rechaza `retry_on_failure` | Cloud Run no arrancaba |
| Managed Prometheus rechaza TimeSeries duplicadas | Se quitó `batch` del pipeline de métricas |

Y uno más, encontrado durante el Módulo B: los tres servicios declaraban
`http_requests_total` con textos de `HELP` distintos. En Prometheus el nombre
de una métrica es global, así que la librería cliente **rechazaba la colección
entera**:

```
error gathering metrics: 6 error(s) occurred:
* collected metric http_requests_total ... has help "...por service-a"
  but should have "...por data-service"
```

Llevaba fallando desde antes del módulo y explicaba huecos en las series que
hasta entonces no tenían causa conocida.

**Qué falta para el 5.** No hay cola persistente (`file_storage`): si el
Collector se reinicia, se pierde lo que tuviera en el *batch*. Tampoco hay
muestreo adaptativo — el muestreo es 100 % y eso no escala.

---

### 3. Correlación entre señales — nivel 3

**Evidencia.** El `trace_id` viaja en las tres señales. Grafana salta de log a
traza (`derivedFields`), de traza a log (`tracesToLogsV2`) y de traza a métrica
(`tracesToMetrics`). La propagación W3C entre los tres servicios está
verificada: una petición produce un único `trace_id` compartido.

**Por qué 3 y no 4.** Falta el salto **de métrica a traza**. Los exemplars son
el mecanismo estándar y aquí no existen: el SDK de OpenTelemetry para Python
1.27 no los implementa, y da igual que el Collector exponga OpenMetrics y que
Prometheus tenga `exemplar-storage` activado.

El Módulo B lo resuelve preguntando al backend de trazas en vez de al de
métricas, lo cual funciona —y es más robusto, porque selecciona por *tiene
error* en vez de por *fue lento*— pero es un rodeo, no la capacidad estándar.

**Qué falta para el 4.** Subir el SDK a una versión con exemplars y comprobar
que el salto funciona desde el panel, no solo desde un script.

---

### 4. SLO y presupuesto de error — nivel 3

**Evidencia.** SLO explícitos (disponibilidad 99,5 %, p99 1.000 ms, p95 500 ms)
y cálculo de consumo de presupuesto con tasa de quemado en cada experimento de
caos. La política de Cloud Monitoring usa el umbral de 14,4× del SRE Workbook.

**Por qué 3 y no 4.** Dos problemas de gobierno, no de técnica:

1. **El SLO está definido en tres sitios**: el panel de Grafana,
   `aiops/detector.py` y `terraform/observabilidad/variables.tf`. Cada uno
   documenta que los otros existen, pero nada impide que diverjan.
2. **Nadie ha revisado nunca el presupuesto.** Se calcula por experimento y se
   imprime; no hay una revisión periódica que convierta el número en una
   decisión.

El segundo punto es el que separa el 3 del 4: un presupuesto de error que no
cambia ninguna decisión es un número bonito.

---

### 5. Alertado y respuesta — nivel 3

**Evidencia.** Seis políticas como código, cada una con su *runbook* en el
propio campo de documentación: qué pasó, qué mirar primero, y una tabla de
causas vistas en el laboratorio. La regla correlacionada se validó contra un
escenario con ruido y con incidente:

```
  enfoque                       alertas     útiles   sin acción
  umbral fijo p99 > 500 ms            2          1            1
  umbral fijo p99 > 2000 ms           2          1            1
  baseline + correlación              1          1            0
```

50 % menos ruido, cero incidentes perdidos, y la alerta adjunta la traza
exacta: `fetch.order.db → HTTPException: 500: Database error`.

**Por qué 3 y no 4.** El MTTD se mide, pero los resultados son irregulares y
eso aún no ha cambiado nada:

| Experimento | MTTD |
|---|---|
| E1 — latencia de red | **sin detección en 120 s** |
| E2 — agotamiento de CPU | 0 s |
| E4 — errores en dependencia opcional | 28 s |

E1 no se detectó porque la degradación no cruzaba ningún umbral configurado.
Ese dato existe desde el Game Day y todavía no ha producido una alerta nueva.

Y falta todo lo humano: no hay rotación de guardia, ni escalado, ni
*postmortems*. Un alertado sin destinatario definido no es un proceso.

---

### 6. Observabilidad de infraestructura y red — nivel 2

**Evidencia.** VPC Flow Logs definidos en las dos nubes, con formato extendido
en AWS para distinguir tráfico este-oeste de norte-sur; cuatro métricas
derivadas de logs en GCP y tres filtros métricos en AWS; cuatro consultas
guardadas de Logs Insights, incluida la que parte de un `trace_id`.

**Por qué 2 y no 3.** *Nada de esto se ha ejecutado.* El Terraform valida, pero
validar no es desplegar. Un filtro de métrica posicional sobre Flow Logs es
especialmente frágil: depende del orden exacto de los campos del `log_format`,
y eso solo se comprueba viendo pasar un log real.

**Qué falta para el 3.** Desplegar, generar tráfico, y confirmar que las cuatro
métricas se pueblan.

---

### 7. Seguridad — nivel 2

**Evidencia.** mTLS `STRICT` en toda la malla, `AuthorizationPolicy` de
denegación por defecto, y permisos explícitos por identidad SPIFFE acotados a
método y ruta. Panel de *Señales Doradas de Seguridad* con cuatro preguntas:
quién intenta entrar, quién pide de más, qué viaja sin cifrar, qué sale.
GuardDuty y Security Hub como opcionales, apagados por defecto por coste.

**Por qué 2 y no 3.** Mismo motivo que el dominio anterior: está validado con
`istioctl analyze` pero no aplicado a un clúster. La política de denegación por
defecto es justo el tipo de configuración que falla al aplicarse —basta una
ruta legítima no contemplada— y eso solo se ve con tráfico real.

Además, dos de los paneles de seguridad valen **cero** cuando todo está bien.
Eso los hace indistinguibles de un panel roto hasta que se comprueba que las
métricas siguen recibiendo datos.

---

### 8. Resiliencia y cultura de experimentación — nivel 4

**Evidencia.** Cuatro experimentos con el modelo de *probes* de LitmusChaos
(SOT / DuringChaos / EOT), hipótesis falsables, radio de impacto acotado y
*rollback* automático por `trap`.

**Por qué 4, y es el dominio mejor puntuado.** Porque los experimentos han
fallado, y el diseño detectó los fallos en vez de informar de éxitos falsos:

| Qué pasó | Cómo se detectó |
|---|---|
| E4 no inyectó nada: `docker-compose.yaml` fijaba `CHAOS_ERROR_RATE: "0"` literal, así que la variable del shell se ignoraba | El script comprueba que la inyección produjo errores **antes** de evaluar la hipótesis, y devolvió `INVÁLIDO` |
| E4 concluyó "hipótesis refutada" con el cliente al 100 % de disponibilidad | `sli_disponibilidad()` agregaba los tres servicios; el 9,4 % de `data-service` diluido daba 96,86 % |
| `tc netem` no existe en WSL2 (sin `sch_netem`) | Se sustituyó por Toxiproxy y se documentó como restricción real del entorno |

Un experimento que solo sabe confirmar no es un experimento. Los tres casos de
arriba son la evidencia de que este marco sí sabe decir que no.

#### El caso E4: ocho ejecuciones hasta merecer confianza

E4 es trivial —inyectar un 10 % de errores en una dependencia opcional— y su
resultado principal fue estable desde la segunda ejecución. Lo que costó ocho
intentos fue que el **instrumento** mereciera confianza. Cada fallo era
invisible desde fuera: los servicios en verde, respondiendo 200.

| # | Qué falló | Cómo se detectó | Qué lo causaba |
|---|---|---|---|
| 1 | La inyección no ocurrió | El script verifica que hubo errores **antes** de evaluar la hipótesis → `INVÁLIDO` | `docker-compose.yaml` fijaba `CHAOS_ERROR_RATE: "0"` literal; la variable del shell se ignoraba |
| 2 | "Hipótesis refutada" con el cliente al 100 % | Dos cifras del propio informe se contradecían | `sli_disponibilidad()` agregaba los tres servicios |
| 3 | Veredicto `INDETERMINADO` | El script no inventa cuando faltan métricas | La función nueva nunca llegó al archivo (edición abortada) |
| 4 | `+104 %` de p99 atribuido al fallo | El p99 en régimen estable del caos era idéntico al posterior | La ventana incluía el arranque en frío del contenedor recreado |
| 5 | `+62 %` de p99 | El p99 oscilaba entre 74 y 461 ms *dentro de una fase estable* | Se comparaba **una muestra instantánea** de cada fase |
| 6 | Export de logs caído, sin spans SQL | Traza del fallo en los logs del contenedor | `psycopg2-binary` instalado, instrumentación busca `psycopg2` y **se desactivaba en silencio** |
| 7 | El experimento moría a mitad | `fork: Resource temporarily unavailable` | El generador lanzaba ~1.000 procesos; además pedía 8 rps y entregaba 3,2 |
| 8 | "Confirmada" con el p99 a 3.904 ms | Se leyó el valor absoluto, no solo el delta | El SOT daba por sano un sistema **4× fuera de su SLO** porque solo miraba `/health` |

Los cuatro últimos comparten una misma raíz: **el instrumento de medida no
estaba instrumentado**. Un generador que no alcanza su ritmo, una ventana que
mezcla fases, un SLI que agrega lo que no debe y un probe de estado estable que
confunde «responde» con «está sano» son todos el mismo error, y ninguno se ve
mirando el resultado — solo mirando si el resultado tiene sentido.

El hallazgo nº 6 además corrige una afirmación del informe anterior, que decía
que había auto-instrumentación de base de datos. No la había.

**Qué falta para el 5.** Los experimentos se lanzan a mano. El nivel 5 exige
ejecución continua y automática, con los resultados puestos contra el
presupuesto de error.

---

## Hoja de ruta a tres meses

El criterio de ordenación no es la dificultad sino el **coste de no hacerlo**:
primero lo que convierte trabajo ya hecho en capacidad real, después lo que
cubre huecos conocidos, y al final lo que escala.

### Mes 1 — Convertir código en capacidad

Los dominios 6 y 7 están en 2 porque nunca se aplicaron, no porque falte
trabajo. Es el mes con mejor relación entre esfuerzo y nivel ganado.

| Acción | Criterio de salida |
|---|---|
| Desplegar GKE + Istio y aplicar `k8s/` | Los tres servicios con 2/2 contenedores y `istioctl x describe` confirmando mTLS |
| Ejercitar las políticas de autorización | Un 403 provocado a propósito aparece en el panel con el `source_principal` correcto |
| Aplicar `terraform/observabilidad` y generar tráfico | Las cuatro métricas de seguridad con datos; el panel deja de estar plano por falta de señal |
| Validar los filtros de Flow Logs de AWS contra logs reales | `ConexionesRechazadas` y `BytesDeSalida` con valores distintos de cero |

**Resultado esperado:** dominios 6 y 7 pasan de 2 a 3. Media 3,1 → 3,4.

### Mes 2 — Cerrar los huecos que ya conocemos

Cada acción de este mes responde a un hallazgo concreto de los laboratorios,
no a una buena práctica genérica.

| Acción | Hallazgo que la motiva |
|---|---|
| Subir el SDK de Python a una versión con exemplars | El salto métrica → traza no existe (dominio 3) |
| Crear una alerta para el modo de fallo de E1 | E1 no se detectó en 120 s porque no cruzaba ningún umbral |
| Unificar la definición de SLO en una sola fuente | Hoy vive en tres sitios que pueden divergir |
| Añadir `file_storage` al Collector | Un reinicio pierde el *batch* en vuelo |
| Instaurar una revisión mensual del presupuesto de error | El número se calcula y nadie lo mira |

**Resultado esperado:** dominios 3, 4 y 5 pasan a 4. Media 3,4 → 3,9.

### Mes 3 — Que funcione sin que nadie empuje

| Acción | Criterio de salida |
|---|---|
| Ejecutar los cuatro experimentos de caos en CI, semanalmente | Una ejecución fallida bloquea el *merge* |
| Muestreo adaptativo: 100 % de errores, porcentaje bajo del resto | El volumen de trazas baja sin perder ninguna traza con error |
| Control automático de cobertura de instrumentación | Un servicio nuevo sin instrumentar falla la validación |
| Definir rotación de guardia y plantilla de *postmortem* | Un incidente real produce un documento, no un hilo de chat |

**Resultado esperado:** dominios 1, 2 y 8 se acercan al 5. Media ≈ 4,3.

---

## La conclusión incómoda

El sistema de este laboratorio está mejor instrumentado que muchos sistemas en
producción, y aun así su media de madurez es **3,1**. La diferencia no está en
la tecnología, que es la misma: está en que la madurez se mide por lo que el
sistema demuestra bajo presión, y gran parte de lo construido aquí todavía no
se ha puesto bajo presión.

El dato que mejor lo resume: de los **ocho** defectos encontrados en una sola
sesión, **ninguno** lo encontró una alerta. Todos los encontró alguien mirando
de cerca un número que no cuadraba. Y seis de los ocho estaban en el propio
instrumental de observabilidad, no en el sistema observado.

Un pipeline de observabilidad que no se observa a sí mismo tiene exactamente el
mismo punto ciego que el sistema que pretende vigilar.
