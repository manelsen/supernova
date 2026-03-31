import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.SUPERNOVA_BASE_URL || 'http://localhost:8080';

export const options = {
  scenarios: {
    budget_exhaustion: {
      executor: 'constant-vus',
      vus: 20,
      duration: '2m',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
  },
};

let sessionsActive = 0;
let budgetExhausted = false;

export default function () {
  const vuId = __VU;

  if (!budgetExhausted) {
    const res = http.get(`${BASE_URL}/health/ready`);
    const ok = check(res, {
      'ready returns 200': (r) => r.status === 200,
    });

    if (!ok) {
      budgetExhausted = true;
    }

    sessionsActive++;
  } else {
    const res = http.get(`${BASE_URL}/health/live`);
    check(res, {
      'live still returns 200 after budget exhaustion': (r) => r.status === 200,
    });
  }

  sleep(0.1);

  if (__ITER === 0) {
    console.log(`VU ${vuId} starting session`);
  }
}

export function handleSummary(data) {
  const out = [
    '\nBUDGET EXHAUSTION TEST RESULTS',
    '',
    `Active sessions: ${sessionsActive}`,
    `Budget exhausted: ${budgetExhausted ? 'YES' : 'NO'}`,
    `Error rate: ${(data.metrics.http_req_failed.values.rate * 100).toFixed(3)}%`,
    `Sessions graceful: ${!budgetExhausted || data.metrics.http_req_failed.values.rate < 0.05 ? 'YES ✓' : 'NO ✗'}`,
  ].join('\n');

  console.log(out);
  return { 'summary.json': JSON.stringify(data) };
}
