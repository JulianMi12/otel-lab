# Evidencias del laboratorio

Capturas generadas automáticamente por `scripts/capturar-evidencias.sh`.

**trace_id de referencia:** `328dc87990f503cdf2166cf39f916b8c`

| Archivo | Qué demuestra |
|---|---|
| `01-jaeger-traza-completa.png` | Traza con spans de service-a **y** service-b bajo un único trace_id: prueba de la propagación W3C TraceContext |
| `02-jaeger-busqueda-trazas.png` | Listado de trazas con sus latencias y relación de servicios |
| `03-grafana-dashboard-slis.png` | Dashboard: 4 SLIs, CPU/memoria por contenedor y errores del OTel Collector |
| `04-grafana-explore-logs-correlacionados.png` | Logs de Loki filtrados por el trace_id: correlación log ↔ traza |
| `05-prometheus-targets.png` | Targets de scraping activos |

Para reproducirlas con el estado actual del sistema:

```bash
docker compose up -d --build
bash scripts/capturar-evidencias.sh
```
