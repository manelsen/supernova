import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.SUPERNOVA_BASE_URL || 'http://localhost:8080';

const CONCURRENCY_LEVELS = [10, 50, 100];

export const options = {
  scenarios: {},
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(99)<2000'],
  },
};

CONCURRENCY_LEVELS.forEach((vus) => {
  const label = `concurrency_${vus}`;
  options.scenarios[label] = {
    executor: 'constant-vus',
    vus: vus,
    duration: '30s',
    tags: { concurrency: String(vus) },
  };
});

export default function () {
  const res = http.get(`${BASE_URL}/health`);
  check(res, {
    'health returns 200': (r) => r.status === 200,
    'health latency < 500ms': (r) => r.timings.duration < 500,
  });
  sleep(0.1);
}

export function handleSummary(data) {
  const lines = ['\nCONCURRENCY TEST RESULTS\n'];
  lines.push(`${'VU'.padEnd(6)} ${'p50'.padEnd(8)} ${'p95'.padEnd(8)} ${'p99'.padEnd(8)} ${'Fail%'.padEnd(8)} ${'Count'.padEnd(8)}`);
  lines.push(`${'--'.repeat(6)} ${'---'.repeat(8)} ${'---'.repeat(8)} ${'---'.repeat(8)} ${'-----'.repeat(8)} ${'-----'.repeat(8)}`);

  for (const vu of CONCURRENCY_LEVELS) {
    const tag = `concurrency=${vu}`;
    const p50 = data.metrics.http_req_duration?.values?.[`p(50){${tag}}`]?.toFixed(2) || 'N/A';
    const p95 = data.metrics.http_req_duration?.values?.[`p(95){${tag}}`]?.toFixed(2) || 'N/A';
    const p99 = data.metrics.http_req_duration?.values?.[`p(99){${tag}}`]?.toFixed(2) || 'N/A';
    const failRate = ((data.metrics.http_req_failed?.values?.[`rate{${tag}}`] || 0) * 100).toFixed(2);
    const count = data.metrics.http_reqs?.values?.[`count{${tag}}`] || 0;
    lines.push(`${String(vu).padEnd(6)} ${p50.padEnd(8)} ${p95.padEnd(8)} ${p99.padEnd(8)} ${failRate.padEnd(8)} ${String(count).padEnd(8)}`);
  }

  console.log(lines.join('\n'));
  return { 'summary.json': JSON.stringify(data) };
}
