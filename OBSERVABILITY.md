# Observability

How to monitor and debug Supernova in production.

## Health Endpoints

Available on port **8080**:

| Endpoint | What it checks | When to alert |
|---------|---------------|--------------|
| `GET /health` | Basic status + uptime | Non-200 |
| `GET /health/live` | Process is alive | Non-200 |
| `GET /health/ready` | Channels + DB configured | Non-200 |

```bash
curl http://localhost:8080/health
curl http://localhost:8080/health/live
curl http://localhost:8080/health/ready
```

## Metrics (Prometheus)

> **REQ-11:** Metrics endpoint not yet integrated.

Once integrated, metrics are exposed at:

```
GET /metrics
```

Expected metrics:

| Metric | Type | Description |
|--------|------|-------------|
| `supernova_llm_requests_total` | Counter | Total LLM calls by provider, model, status |
| `supernova_llm_latency_seconds` | Histogram | LLM call latency by provider |
| `supernova_sessions_active` | Gauge | Currently active sessions |
| `supernova_tool_calls_total` | Counter | Tool invocations by tool name, status |
| `supernova_circuit_open_total` | Counter | Circuit breaker opens by provider |

## Tracing (OpenTelemetry)

> **REQ-12:** Tracing not yet integrated.

Once integrated, configure the OTLP endpoint:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://your-collector:4318
```

Trace context propagated through: `channel → router → executor → LLM → tools`

Key span attributes:
- `trace_id`, `span_id` — correlation
- `agent_id`, `session_id` — session context
- `provider`, `model` — LLM info
- `tool.name` — when in tool calls

## Logs

Structured JSON logs to stdout. In Docker:

```bash
docker compose logs -f supernova | jq .
```

Log levels: `debug`, `info`, `warn`, `error`

## Alerting Rules (Prometheus/Grafana)

Suggested alerts:

```yaml
groups:
  - name: supernova
    rules:
      - alert: SupernovaHealthDown
        expr: probe_success{job="supernova-health"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Supernova health endpoint is down"

      - alert: SupernovaHighErrorRate
        expr: rate(supernova_llm_requests_total{status="error"}[5m]) > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "LLM error rate above 5%"

      - alert: SupernovaCircuitOpen
        expr: increase(supernova_circuit_open_total[5m]) > 0
        labels:
          severity: warning
        annotations:
          summary: "Circuit breaker opened for {{ $labels.provider }}"

      - alert: SupernovaHighLatency
        expr: histogram_quantile(0.99, rate(supernova_llm_latency_seconds_bucket[5m])) > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "LLM p99 latency above 10s for {{ $labels.provider }}"
```

## Dashboard Panels (Grafana)

Recommended panels:

1. **Request Rate** — `rate(supernova_llm_requests_total[5m])` by provider
2. **Error Rate** — `rate(...{status="error"}) / rate(...total)` by provider
3. **Latency p50/p95/p99** — `histogram_quantile(0.99, rate(supernova_llm_latency_seconds_bucket[5m]))`
4. **Active Sessions** — `supernova_sessions_active`
5. **Tool Call Rate** — `rate(supernova_tool_calls_total[5m])` by tool
6. **Circuit Breaker Events** — `increase(supernova_circuit_open_total[5m])`
