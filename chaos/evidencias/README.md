# Evidencias del Game Day

Capturas generadas por `chaos/capturar-evidencias-chaos.sh` tras ejecutar los
tres experimentos. La ventana temporal abarca los tres, de modo que el
dashboard muestra el incidente completo.

| Archivo | Qué demuestra |
|---|---|
| `chaos-01-dashboard-incidente.png` | Los cuatro SLIs durante los tres experimentos: picos de latencia, consumo de CPU y salud del Collector |
| `chaos-02-cpu-stress-ng.png` | Experimento 2: la CPU de service-b saturando su cuota con stress-ng |
| `chaos-03-latencia-percentiles.png` | Los tres picos de latencia, uno por experimento |
| `chaos-04-logs-degradacion.png` | Experimento 3: logs `service-b inalcanzable`, prueba de que el fallback actuó |
| `chaos-05-jaeger-trazas-lentas.png` | Trazas del periodo, incluidas las de ~5 s provocadas por el timeout |

Reproducir:

```bash
docker compose -f docker-compose.yaml -f docker-compose.chaos.yaml up -d
bash chaos/experimentos/e1-latencia-red.sh
bash chaos/experimentos/e2-cpu-exhaustion.sh
bash chaos/experimentos/e3-network-partition.sh
bash chaos/capturar-evidencias-chaos.sh
```
