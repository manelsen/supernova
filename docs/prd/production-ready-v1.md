# PRD — commercially production-ready

**Version:** 1.0  
**Status:** Draft  
**Last updated:** 2026-03-30

---

## 1. Context

The current codebase is feature-complete (v0.2.0) with all 9 channel adapters, 8 LLM providers, and full kernel primitives implemented. However, the system has not been validated against enterprise production requirements. This PRD defines the work needed to reach commercially viable production readiness.

---

## 2. Definition of Done

The system is considered **commercially production-ready** when all criteria below are met:

| # | Criterion | Target |
|---|----------|--------|
| 1 | Deploy 100% automated | Single command (`docker compose up`) |
| 2 | Zero critical mock paths | No silent failures in production code paths |
| 3 | Complete observability | Logs + Metrics + Distributed tracing |
| 4 | Minimal enterprise security | Secrets, isolation, audit |
| 5 | Basic SLA possible | Restart, retry, fallback |
| 6 | Onboarding time | ≤ 15 minutes |
| 7 | Predictable under load | Benchmarks + load tests documented |

---

## 3. Current State Assessment

### 3.1 What's working

| Area | Implementation |
|------|---------------|
| **Supervisor tree** | OTP `SessionSupervisor` with per-session actors; crash recovery automatic |
| **Kernel/userland split** | `SyscallGateway` with WorkspacePolicy, BudgetPolicy, CapabilityManifest |
| **Audit log** | Every operation logged via `supernova_telemetry_ffi` |
| **Budget enforcement** | Per-agent token accounting, cooperative pause/resume via checkpoints |
| **Workspace isolation** | Path-level allow/deny per session |
| **Failover** | `llm/failover.gleam` tries providers in order |
| **Rate limiting** | All channel adapters handle 429 with `retry_after` |
| **Reconnection** | MCP adapter has reconnect logic with `max_reconnect_attempts: 5` |
| **Secrets** | Env var overrides for all API keys via `envoy` |
| **Onboarding** | `gleam run -m supernova/wizard_main` interactive setup |
| **Logging** | Structured logs (Debug/Info/Warning/Error) per component |

### 3.2 Gaps

| Gap | Severity | File |
|-----|----------|------|
| `case "mock"` in failover returns hardcoded response silently | **Critical** | `src/supernova/llm/failover.gleam:102-108` |
| No distributed tracing (OpenTelemetry) | High | Missing |
| No Prometheus metrics export | High | Missing |
| No circuit breaker for LLM calls | High | Missing |
| Failover has no cooldown between provider attempts | High | `src/supernova/llm/failover.gleam` |
| No retry with exponential backoff | Medium | Missing |
| No load testing suite | Medium | Missing |
| No benchmark suite | Medium | Missing |
| No TLS configuration for external APIs | Medium | `src/supernova/tools/gateway.gleam` |
| No secret rotation mechanism | Medium | Config only |
| No RBAC (role-based access) | Low | Not scoped |
| Docker image not optimized (build context) | Low | `Dockerfile` |
| No health check endpoint (`/health`) | Low | `supernova.gleam` |

---

## 4. Requirements

### REQ-1: Remove Silent Mock Fallback

**Priority:** Critical

The `failover.chat()` function contains a `"mock"` case that returns `"Mock response"` deterministically. If a user mistakenly configures `provider: "mock"` in production, the system will appear to work but return fake responses silently.

**Acceptance criteria:**
- `failover.gleam` returns `Error(provider.ProviderNotFound)` for unknown provider names
- `provider_not_found` is a hard error, not a fallback
- Unit test confirms unknown provider raises error

**Owner:** Backend

---

### REQ-2: Health Check Endpoint

**Priority:** High

The system cannot be monitored by orchestrators (Kubernetes, Docker Compose healthcheck) without a `/health` endpoint.

**Acceptance criteria:**
- `GET /health` returns `200 OK` with `{"status": "ok", "uptime_seconds": N}`
- `GET /health/ready` returns `200 OK` when all channels and the LLM provider are connected
- `GET /health/live` returns `200 OK` when the BEAM node is alive
- Docker Compose healthcheck uses `/health/live`

**Owner:** Backend

---

### REQ-3: OpenTelemetry Tracing

**Priority:** High

Production systems require distributed tracing to debug latency issues across agents, LLM calls, and tool executions.

**Acceptance criteria:**
- Trace context propagated through the full request lifecycle: channel → router → executor → LLM → tools
- Each span includes: `trace_id`, `span_id`, `agent_id`, `session_id`
- Spans exported via OTLP HTTP (configurable endpoint)
- Trace sampling rate configurable (default 10%)
- Zero-cost tracing when disabled

**Owner:** Backend

---

### REQ-4: Prometheus Metrics

**Priority:** High

Prometheus is the standard metrics format for production Kubernetes deployments.

**Acceptance criteria:**
- `/metrics` endpoint in Prometheus format
- Metrics exposed:
  - `supernova_sessions_active` (gauge)
  - `supernova_llm_requests_total` (counter, labels: provider, model, status)
  - `supernova_llm_latency_seconds` (histogram)
  - `supernova_tool_calls_total` (counter, labels: tool_name, status)
  - `supernova_budget_tokens_used` (counter, labels: agent_id)
  - `supernova_channel_messages_total` (counter, labels: channel, status)
  - `supernova_errors_total` (counter, labels: component, error_type)
- Grafana dashboard JSON provided

**Owner:** Backend

---

### REQ-5: Circuit Breaker for LLM Calls

**Priority:** High

When an LLM provider is down, repeated retries exhaust resources and delay error reporting to users.

**Acceptance criteria:**
- Circuit breaker per provider (OpenAI, Anthropic, etc.)
- States: **Closed** (normal) → **Open** (failures exceed threshold) → **Half-Open** (test)
- Closed: requests pass through; failures counted
- Open: requests fail immediately with `CircuitOpen` error; no LLM calls made
- Half-open: one test request allowed; success → Closed, failure → Open
- Thresholds configurable: failure threshold (default 5), recovery timeout (default 60s)
- Circuit state observable via telemetry

**Owner:** Backend

---

### REQ-6: Failover Cooldown

**Priority:** High

Current failover tries providers sequentially without delay. On repeated failures, this hammers failing endpoints.

**Acceptance criteria:**
- After a provider fails, it enters a **cooldown** period (default 30s)
- During cooldown, the provider is skipped
- Cooldown duration increases exponentially on repeated failures (30s → 60s → 120s → max 5min)
- Cooldown cleared after successful request
- Cooldown per provider, not global

**Owner:** Backend

---

### REQ-7: Retry with Exponential Backoff

**Priority:** Medium

Transient failures (network blips, temporary rate limits) should be retried with backoff.

**Acceptance criteria:**
- Retry on: network errors, 429 rate limit, 5xx server errors
- Do NOT retry on: 4xx client errors (except 429), validation errors, circuit open
- Backoff: initial 1s, max 30s, exponential factor 2x, jitter ±20%
- Max attempts configurable (default 3)
- Each retry attempt logged with attempt number

**Owner:** Backend

---

### REQ-8: Load Testing Suite

**Priority:** Medium

The system must be validated under concurrent load before production deployment.

**Acceptance criteria:**
- k6 (or similar) load test suite in `tests/load/`
- Test scenarios:
  - `smoke_test.js` — single user, single message, verify 200 OK
  - `concurrency_test.js` — 10, 50, 100 concurrent users, verify p99 latency < 2s
  - `sustained_load.js` — 50 concurrent users for 5 minutes, verify throughput
  - `budget_exhaustion.js` — verify cooperative pause behavior under budget
- Results documented: latency percentiles, throughput, error rate
- CI gate: load tests run before merge to master

**Owner:** QA / Backend

---

### REQ-9: Benchmark Suite

**Priority:** Medium

Baseline performance metrics must exist to detect regressions.

**Acceptance criteria:**
- Benchmark suite in `tests/bench/`
- Measures:
  - LLM round-trip latency (with mock, with real provider)
  - Channel dispatch latency per adapter
  - Session creation throughput (sessions/second)
  - Tool call overhead
- Reported in PR comments on changes touching core path
- Baseline committed as `BENCHMARKS.md`

**Owner:** Backend

---

### REQ-10: Single-Command Deploy

**Priority:** Medium

Production deployment must not require manual file preparation.

**Acceptance criteria:**
- `docker compose up` works with `.env` file only (no manual YAML editing)
- `supernova.yaml` generated from env vars if not present
- Wizard runs automatically on first boot if no config
- Healthcheck configured
- Restart policy `unless-stopped`

**Owner:** DevOps

---

### REQ-11: Metrics Integration

**Priority:** High

The Prometheus metrics module exists but is not started or exposed. The `/metrics` endpoint is not available.

**Acceptance criteria:**
- `metrics/actor.gleam` started as a singleton actor during `start_services()`
- `/metrics` HTTP endpoint returns Prometheus-formatted metrics
- `supernova_llm_requests_total`, `supernova_llm_latency_seconds`, `supernova_sessions_active` counters/gauges exposed
- Metrics actor stopped gracefully on shutdown

**Owner:** Backend

---

### REQ-12: Tracing Integration

**Priority:** High

The OpenTelemetry tracing module exists but is not started or configured. Trace context is not propagated.

**Acceptance criteria:**
- `tracing/actor.gleam` started as a singleton actor during `start_services()`
- Trace context propagated through channel → router → executor → LLM → tools
- OTLP HTTP exporter configured via `OTEL_EXPORTER_OTLP_ENDPOINT`
- `trace_id`, `span_id`, `agent_id`, `session_id` included in each span
- Tracing actor stopped gracefully on shutdown

**Owner:** Backend

---

### REQ-13: Circuit Breaker Integration

**Priority:** High

The circuit breaker module exists but is not wired into the LLM call path.

**Acceptance criteria:**
- `circuit_breaker.gleam` used in `failover.gleam` or `client.gleam`
- Per-provider circuit breakers created and consulted before each LLM call
- `CircuitOpen` error returned immediately when circuit is open
- Circuit state observable via metrics (circuit_open_total counter)

**Owner:** Backend

---

### REQ-14: Failover Cooldown Integration

**Priority:** High

The failover cooldown module exists but is not wired into LLM calls.

**Acceptance criteria:**
- `failover_cooldown/actor.gleam` started as singleton during `start_services()`
- `failover.chat_with_cooldown()` used instead of bare `failover.chat()` in the executor
- Provider cooldown state updated on success/failure
- Cooldown observable via telemetry events

**Owner:** Backend

---

### REQ-15: Retry Integration

**Priority:** Medium

The retry module exists but is not wired into LLM calls.

**Acceptance criteria:**
- `retry.with_retry()` wraps LLM calls in the executor or client
- Configurable via `RETRY_MAX_ATTEMPTS`, `RETRY_INITIAL_DELAY_MS`, `RETRY_MAX_DELAY_MS`
- Retry events (`retry.attempt`, `retry.giveup`) visible in telemetry
- Jitter applied to avoid thundering herd

**Owner:** Backend

---

### REQ-16: Parallel SubAgent Planning

**Priority:** High

The Executor runs sequentially by default. SubAgents exist but must be explicitly invoked via tool — the agent cannot decide on its own when to parallelize.

To enable autonomous parallelization, three pieces are required:

**1. Planning step in Executor**

Before executing, the Executor makes a planning decision:
- If the LLM response contains multiple independent tasks → dispatch SubAgents in parallel
- If it is a single task → run in the normal loop

Implementation: after LLM responds, run a lightweight "task decomposition" prompt that detects parallelizable work.

**2. Non-blocking Session.Server orchestrator**

The Session.Server needs an orchestrator mode — instead of blocking waiting for Executor result, it:
- Dispatches SubAgents
- Sends an immediate "working in parallel on X tasks..." response to the user
- Remains available for new messages while waiting

Implementation: Session.Server becomes event-driven, using `process.send_after` for partial responses.

**3. Progress notification to user**

The user receives incremental updates:
- Initial: "I'm working on 3 parallel tasks..."
- Per task completion: "Task 1 done. 2 remaining."
- Final: aggregated response

Implementation: channel adapters receive `PortPartialResponse` events and relay them to the user.

**Acceptance criteria:**
- Executor detects independent tasks in LLM response via planning prompt
- Session.Server dispatches SubAgents in parallel without blocking
- User receives immediate acknowledgment with task list
- User receives progress updates as each SubAgent completes
- Final response aggregates all SubAgent results
- Sequential fallback when parallelization is not warranted

**Owner:** Backend

---

## 5. Non-Goals (Out of Scope for v1.0)

These are not targeted for the first production release:

| Item | Reason |
|------|--------|
| Multi-node / cluster mode | Single instance handles moderate load |
| RBAC / permissions model | Not required for initial deployment |
| TLS for internal BEAM communication | Not exposed externally |
| Secret rotation automation | Manual process acceptable for v1 |
| Kubernetes Helm chart | Docker Compose sufficient for v1 |
| SSO / OAuth | External auth not in scope |

---

## 6. Dependencies

| Requirement | Depends on |
|-------------|-----------|
| REQ-3 (Tracing) | None |
| REQ-4 (Metrics) | None |
| REQ-5 (Circuit Breaker) | None |
| REQ-6 (Cooldown) | None |
| REQ-7 (Retry) | REQ-5 |
| REQ-8 (Load Tests) | REQ-3, REQ-4 |
| REQ-9 (Benchmarks) | REQ-3 |
| REQ-10 (Deploy) | None |
| REQ-11 (Metrics Integration) | REQ-4 |
| REQ-12 (Tracing Integration) | REQ-3 |
| REQ-13 (Circuit Breaker Integration) | REQ-5 |
| REQ-14 (Failover Cooldown Integration) | REQ-6 |
| REQ-15 (Retry Integration) | REQ-7 |
| REQ-16 (Parallel SubAgent Planning) | SubAgent system, REQ-13, REQ-14, REQ-15 |

---

## 7. Timeline

| Phase | Work | Estimate |
|-------|------|----------|
| **Phase 1** | REQ-1 (mock fix), REQ-2 (health), REQ-5 (circuit breaker), REQ-6 (cooldown) | 2 days |
| **Phase 2** | REQ-3 (tracing), REQ-4 (metrics), REQ-7 (retry) | 3 days |
| **Phase 3** | REQ-8 (load tests), REQ-9 (benchmarks), REQ-10 (deploy) | 2 days |
| **Phase 4** | Integration testing, bug fixes, documentation | 2 days |

**Total estimate:** 7-9 days

---

## 8. Success Metrics

The system is production-ready when:

- [ ] All 16 requirements implemented and accepted
- [ ] Load test passes: 100 concurrent users, p99 < 2s, error rate < 1%
- [ ] Zero `mock` or `placeholder` strings in non-test code paths
- [ ] `/health`, `/metrics`, `/health/ready` all return 200 in deployment
- [ ] Trace spans visible in Grafana or Jaeger for a complete agent session
- [ ] Circuit breaker triggers within 5 failures, recovers within 60s
- [x] Documentation updated: `DEPLOY.md`, `OBSERVABILITY.md`
