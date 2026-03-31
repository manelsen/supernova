import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.SUPERNOVA_BASE_URL || 'http://localhost:8080';

export const options = {
  scenarios: {
    smoke: {
      executor: 'constant-vus',
      vus: 1,
      duration: '30s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  },
};

export default function () {
  const healthRes = http.get(`${BASE_URL}/health`);
  check(healthRes, {
    'health returns 200': (r) => r.status === 200,
    'health has status ok': (r) => JSON.parse(r.body).status === 'ok',
    'health has uptime_seconds': (r) => typeof JSON.parse(r.body).uptime_seconds === 'number',
  });

  const liveRes = http.get(`${BASE_URL}/health/live`);
  check(liveRes, {
    'health/live returns 200': (r) => r.status === 200,
    'health/live body is ok': (r) => r.body === 'ok',
  });

  const readyRes = http.get(`${BASE_URL}/health/ready`);
  check(readyRes, {
    'health/ready returns 200': (r) => r.status === 200,
    'health/ready has status': (r) => typeof JSON.parse(r.body).status === 'string',
  });

  sleep(1);
}

export function handleSummary(data) {
  const duration = data.state.testDurationSeconds || 0;
  const totalReqs = data.metrics.http_reqs?.values?.count || 0;
  const failRate = (data.metrics.http_req_failed?.values?.rate || 0) * 100;
  const p95 = data.metrics.http_req_duration?.values?.p95 || 0;

  const out = [
    '\nSMOKE TEST RESULTS',
    '',
    `Duration:        ${duration.toFixed(1)}s`,
    `Total requests:  ${totalReqs}`,
    `Failed requests: ${data.metrics.http_req_failed?.values?.passes || 0}`,
    `Pass rate:       ${(100 - failRate).toFixed(1)}%`,
    `p95 latency:     ${p95}ms`,
  ].join('\n');

  console.log(out);
  return {
    'stdout': out,
    'summary.json': JSON.stringify(data),
  };
}
