/**
 * ════════════════════════════════════════════════════════════════════════════
 * load.js — Generador de carga k6 para el benchmark de overhead de OpenTelemetry
 *
 * El mismo script se ejecuta DOS veces contra dos despliegues idénticos salvo
 * por la instrumentación:
 *
 *   1. Línea base   TARGET=http://service-a-baseline:8000   (OTEL_ENABLED=false)
 *   2. Instrumentado TARGET=http://service-a:8000           (OTEL_ENABLED=true)
 *
 * Ejecutar la misma carga contra ambos es lo que permite atribuir la diferencia
 * de latencia, CPU y memoria exclusivamente al costo de OTel.
 *
 * Uso:
 *   docker compose --profile load run --rm \
 *     -e TARGET=http://service-a:8000 -e SCENARIO=instrumented \
 *     k6 run /scripts/load.js
 * ════════════════════════════════════════════════════════════════════════════
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import { randomSeed } from 'k6';

// El 5% del tráfico consulta pedidos inexistentes a propósito, para ejercitar
// el camino de error. Por defecto k6 contabiliza cualquier 4xx como petición
// fallida, lo que inflaría http_req_failed con errores que son el resultado
// CORRECTO de la prueba. Declarar 404 como estado esperado hace que la tasa de
// error del benchmark refleje solo fallos reales del servicio.
http.setResponseCallback(http.expectedStatuses(200, 404));

// ── Parámetros de la corrida ────────────────────────────────────────────────
const TARGET   = __ENV.TARGET   || 'http://service-a:8000';
const SCENARIO = __ENV.SCENARIO || 'instrumented';
const VUS      = parseInt(__ENV.VUS || '75', 10);
const DURATION = __ENV.DURATION || '5m';
const RAMP     = __ENV.RAMP || '30s';

// Semilla fija: ambas corridas recorren exactamente la misma secuencia de
// pedidos. Sin esto, una corrida podría tocar más pedidos inexistentes que la
// otra y la comparación de latencias quedaría sesgada.
randomSeed(20261014);

// ── Métricas propias ────────────────────────────────────────────────────────
const orderLatency     = new Trend('business_order_latency', true);
const inventoryLatency = new Trend('business_inventory_latency', true);
const tracedRequests   = new Counter('responses_with_trace_id');
const businessErrors   = new Counter('business_errors');

// Los 40 pedidos sembrados por init-db.sql.
const ORDER_IDS = Array.from({ length: 40 }, (_, i) =>
  'ORD-' + String(i + 1).padStart(4, '0')
);

export const options = {
  scenarios: {
    // Carga sostenida de 50-100 usuarios concurrentes durante 5 minutos,
    // como exige el enunciado del laboratorio.
    carga_sostenida: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: RAMP,     target: VUS },  // rampa de subida
        { duration: DURATION, target: VUS },  // meseta: ventana de medición
        { duration: '15s',    target: 0 },    // rampa de bajada
      ],
      gracefulRampDown: '15s',
    },
  },

  // Umbrales: k6 falla la corrida si el servicio no sostiene estos SLOs.
  thresholds: {
    http_req_duration: ['p(95)<800', 'p(99)<1500'],
    http_req_failed:   ['rate<0.05'],
    checks:            ['rate>0.95'],
  },

  // Percentiles explícitos: p99 es el que se compara en el análisis de overhead.
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],

  tags: {
    scenario_name: SCENARIO,
  },
};

export function setup() {
  // Verificación previa: si el objetivo no responde, es preferible fallar de
  // inmediato antes que producir cinco minutos de resultados inválidos.
  const res = http.get(`${TARGET}/health`, { timeout: '10s' });
  if (res.status !== 200) {
    throw new Error(`El objetivo ${TARGET} no está saludable (HTTP ${res.status})`);
  }
  console.log(`Iniciando escenario "${SCENARIO}" contra ${TARGET} con ${VUS} VUs`);
  return { target: TARGET, startedAt: new Date().toISOString() };
}

export default function (data) {
  // Mezcla de tráfico representativa de un sistema real:
  //   85% consultas de pedidos (camino completo A → DB → B → DB)
  //   10% listados (solo A → DB)
  //    5% pedidos inexistentes (ejercita el camino de error 404)
  const roll = Math.random();

  if (roll < 0.85) {
    consultarPedido(data.target);
  } else if (roll < 0.95) {
    listarPedidos(data.target);
  } else {
    consultarPedidoInexistente(data.target);
  }

  // Think time: sin pausa, k6 saturaría la CPU del generador y mediría el
  // límite del cliente en vez del del servicio.
  sleep(Math.random() * 0.4 + 0.1);
}

function consultarPedido(target) {
  const orderId = ORDER_IDS[Math.floor(Math.random() * ORDER_IDS.length)];
  const res = http.get(`${target}/order/${orderId}`, {
    tags: { name: 'GET /order/{id}', operation: 'get_order' },
    timeout: '15s',
  });

  orderLatency.add(res.timings.duration);

  const ok = check(res, {
    'pedido: status 200':        (r) => r.status === 200,
    'pedido: trae total':        (r) => r.json('total_amount') !== undefined,
    'pedido: trae inventario':   (r) => r.json('inventory') !== undefined,
  });

  if (!ok) {
    businessErrors.add(1);
    return;
  }

  // Validación de correlación: en el escenario instrumentado cada respuesta
  // debe traer un trace_id de 32 caracteres hexadecimales (W3C TraceContext).
  // Es la comprobación automatizada de que la propagación no se rompió.
  const traceId = res.json('trace_id');
  if (traceId && /^[0-9a-f]{32}$/.test(traceId)) {
    tracedRequests.add(1);
  }

  const inv = res.json('inventory');
  if (inv && inv.available !== undefined) {
    inventoryLatency.add(res.timings.waiting);
  }
}

function listarPedidos(target) {
  const res = http.get(`${target}/orders`, {
    tags: { name: 'GET /orders', operation: 'list_orders' },
    timeout: '10s',
  });
  check(res, {
    'listado: status 200':  (r) => r.status === 200,
    'listado: trae ids':    (r) => Array.isArray(r.json('order_ids')),
  });
}

function consultarPedidoInexistente(target) {
  const res = http.get(`${target}/order/ORD-9999`, {
    tags: { name: 'GET /order/{id} (404)', operation: 'not_found' },
    timeout: '10s',
  });
  // Un 404 aquí es el comportamiento correcto, no un fallo de la prueba.
  check(res, {
    'inexistente: status 404': (r) => r.status === 404,
  });
}

export function teardown(data) {
  console.log(`Escenario "${SCENARIO}" finalizado. Inicio: ${data.startedAt}`);
}

/**
 * Resumen personalizado: además del reporte estándar de k6, escribe un JSON
 * compacto por escenario que consume analyze_overhead.py para construir la
 * tabla comparativa del reporte.
 */
export function handleSummary(data) {
  const m = data.metrics;
  const get = (name, stat) =>
    m[name] && m[name].values && m[name].values[stat] !== undefined
      ? Number(m[name].values[stat].toFixed(3))
      : null;

  const resumen = {
    escenario: SCENARIO,
    objetivo: TARGET,
    vus_maximos: VUS,
    duracion_meseta: DURATION,
    requests_totales: get('http_reqs', 'count'),
    rps_promedio: get('http_reqs', 'rate'),
    latencia_ms: {
      avg: get('http_req_duration', 'avg'),
      med: get('http_req_duration', 'med'),
      p90: get('http_req_duration', 'p(90)'),
      p95: get('http_req_duration', 'p(95)'),
      p99: get('http_req_duration', 'p(99)'),
      max: get('http_req_duration', 'max'),
    },
    // waiting = time to first byte: aísla el tiempo de proceso del servidor
    // del costo de establecer la conexión.
    servidor_ms: {
      avg: get('http_req_waiting', 'avg'),
      p95: get('http_req_waiting', 'p(95)'),
      p99: get('http_req_waiting', 'p(99)'),
    },
    tasa_error: get('http_req_failed', 'rate'),
    respuestas_con_trace_id: get('responses_with_trace_id', 'count'),
    errores_negocio: get('business_errors', 'count'),
  };

  const nombreArchivo = `/results/k6-${SCENARIO}.json`;

  return {
    [nombreArchivo]: JSON.stringify(resumen, null, 2),
    stdout: textSummary(resumen),
  };
}

function textSummary(r) {
  const l = r.latencia_ms;
  return `
════════════════════════════════════════════════════════════
  RESUMEN — escenario: ${r.escenario}
════════════════════════════════════════════════════════════
  Objetivo            ${r.objetivo}
  Requests totales    ${r.requests_totales}
  Throughput          ${r.rps_promedio} req/s
  Latencia  avg       ${l.avg} ms
            p95       ${l.p95} ms
            p99       ${l.p99} ms
  Tasa de error       ${(r.tasa_error * 100).toFixed(2)} %
  Respuestas con
  trace_id válido     ${r.respuestas_con_trace_id || 0}
════════════════════════════════════════════════════════════
`;
}
