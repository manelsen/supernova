# Load Tests

k6-based load test suite for Supernova production readiness validation.

## Prerequisites

Install k6:
```bash
# macOS
brew install k6

# Linux
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update
sudo apt-get install k6

# Docker
docker pull grafana/k6
```

## Running Tests

Set the base URL (defaults to `http://localhost:8080`):
```bash
export SUPERNOVA_BASE_URL=http://localhost:8080
```

### Smoke Test (single user)
```bash
k6 run tests/load/smoke_test.js
```

### Concurrency Test (10, 50, 100 VUs)
```bash
k6 run tests/load/concurrency_test.js
```

### Sustained Load (50 VUs x 5 minutes)
```bash
k6 run tests/load/sustained_load.js
```

### Budget Exhaustion (20 VUs x 2 minutes)
```bash
k6 run tests/load/budget_exhaustion.js
```

### Run All
```bash
make load-tests
# or
./run_load_tests.sh
```

## CI Gate

In CI, run smoke test first:
```bash
k6 run --quiet tests/load/smoke_test.js
```

Pass criteria: 100% pass rate, p95 < 500ms.

## Expected Results

| Test | VUs | Duration | p99 Target | Error Rate |
|------|-----|----------|------------|------------|
| Smoke | 1 | 10s | <500ms | <1% |
| Concurrency | 10/50/100 | 30s each | <2000ms | <1% |
| Sustained | 50 | 5min | <2000ms | <1% |
| Budget | 20 | 2min | N/A | <5% |

## Notes

- Health server must be running (port 8080 by default).
- Set `SUPERNOVA_BASE_URL` env var to override.
- Use `K6_OUT=k6-http` for HTTP output format in CI.
