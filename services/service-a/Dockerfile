# ════════════════════════════════════════════════════════════════════════════
# service-a — imagen de la aplicación instrumentada con OpenTelemetry
#
# El contexto de build es ./services (no ./services/service-a) para poder copiar el
# módulo compartido common/telemetry.py, que centraliza los tres pilares.
#
# Build: docker compose build service-a
# ════════════════════════════════════════════════════════════════════════════
FROM python:3.12-slim

# Sin .pyc y con stdout sin buffer: los logs JSON salen en tiempo real al
# Collector en vez de quedarse retenidos en el buffer del proceso.
ENV PYTHONDONTWRITEBYTECODE=1     PYTHONUNBUFFERED=1     PYTHONPATH=/app

WORKDIR /app

# curl se usa para el healthcheck de docker compose.
RUN apt-get update  && apt-get install -y --no-install-recommends curl  && rm -rf /var/lib/apt/lists/*

# Las dependencias van en una capa propia: cambiar el código no reinstala pip.
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --upgrade pip  && pip install --no-cache-dir -r /app/requirements.txt

COPY common/ /app/common/
COPY service-a/main.py /app/main.py

EXPOSE 8000
EXPOSE 9464

# Un solo worker: con varios, cada proceso exportaría métricas por separado y
# el endpoint /metrics devolvería valores distintos en cada scrape.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-access-log"]
