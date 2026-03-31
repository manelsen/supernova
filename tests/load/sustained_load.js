import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.SUPERNOVA_BASE_URL || 'http://localhost:8080';

export const options = {
  scenarios: {
    sustained_load: {
      executor: 'constant-vus',
      vus: 50,
      duration: '5m',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(99)<2000'],
    http_reqs: ['rate>10'],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}/health`);
  const ok = check(res, {
    'health returns 200': (r) => r.status === 200,
    'health latency < 500ms': (r) => r.timings.duration < 500,
  });

  if (!ok) {
    http.get(`${BASE_URL}/health/live`);
  }

  sleep(0.5);
}

export function handleSummary(data) {
  const duration = data.state.testDurationSeconds || 0;
  const totalReqs = data.metrics.http_reqs.values.count;
  const throughput = totalReqs / duration;
  const p99 = data.metrics.http_req_duration.values['p(99)'];
  const failRate = data.metrics.http_req_failed.values.rate * 100;

  const out = [
    '\nSUSTAINED LOAD TEST RESULTS (50 VUs x 5 minutes)',
    '',
    `Duration:        ${duration.toFixed(1)}s`,
    `Total requests:  ${totalReqs}`,
    `Throughput:      ${throughput.toFixed(2)} req/s`,
    `p99 latency:     ${p99?.toFixed(2) || 'N/A'}ms`,
    `Error rate:      ${failRate.toFixed(3)}%`,
    `Target met:      ${failRate < 1 && p99 < 2000 ? 'YES ✓' : 'NO ✗'}`,
  ].join('\n');

  console.log(out);
  return {
    'stdout': out,
    'summary.json': JSON.stringify(data),
  };
}
