# Supernova Implementation Status

**Last updated:** 2026-11-18
**Version:** `0.4.0` (`gleam.toml`)
**Toolchain:** Erlang `28.5.0.8` / Gleam `1.19.2` (`.tool-versions`)

---

## Quality Metrics

| Check | Result | Notes |
|-------|--------|-------|
| `gleam format --check src test` | Passing | Clean formatting |
| `gleam build --warnings-as-errors` | Passing | 0 warnings |
| `gleam test` | See `docs/B1_REPORT.md` | Offline suite (`SUPERNOVA_BROWSER_TESTS=1` opt-in for live Chromium) |
| `make coverage` | `75.07%` (`10093/13444` lines) | Exceeds `75.00%` CI gate (`--threshold 75`) |
| Docker smoke test | Verified (`HTTP 200` on `/health/live`) | Tested with offline `ollama` config (`test/fixtures/docker/supernova.yaml`) |
| Audit status (`audit/STATUS_2026-11.md`) | `20 RESOLVIDO`, `5 ACEITO`, `0 ABERTO` | Deferred items tracked for PRD B |

---

## Verified Component Matrix

### Channel Adapters & Routing

| Channel | Implementation Status | Test Coverage Scope |
|---------|-----------------------|---------------------|
| Discord | Implemented & wired | Unit + mocked adapter/router/streaming/keepalive tests |
| Telegram | Implemented & wired | Unit + mocked polling/callback/router/streaming/keepalive tests |
| Slack | Implemented & wired | Unit + mocked native stream & block-kit router tests |
| Matrix | Implemented & wired | Unit + mocked room/edit streaming & router tests |
| Google Chat | Implemented & wired | Unit + webhook parsing/router tests |
| Lark | Implemented & wired | Unit + event parsing/router tests |
| Mattermost | Implemented & wired | Unit + REST parsing/router tests |
| WeChat Work | Implemented & wired | Unit + webhook parsing/router tests |
| WhatsApp | Implemented & wired | Unit + bridge API parsing/router tests |

### LLM Providers & Execution

| Component | Implementation Status | Test Coverage Scope |
|-----------|-----------------------|---------------------|
| LLM Client (`openai`, `anthropic`, `openrouter`, `opencode_zen`, `zhipu`, `zhipu_coding`, `minimax`, `ollama`) | Implemented | Request/response mapping, circuit breaker, cooldown, mock mode, and loopback stream tests |
| Kernel Primitives (`KernelScheduler`, `BudgetPolicy`, `WorkspacePolicy`, `CapabilityManifest`, `ResourceLedger`, `AuditLog`, `WorldModel`, `SyscallGateway`) | Implemented | Unit and OTP actor lifecycle tests with isolated temp workspaces |
| Built-in Tools (`file_system`, `safe_shell`, `web`, `browser`, `github`, `gateway`, `canvas`, `process`) | Implemented | Policy, SSRF, and path-containment unit tests; real Chromium gated by `SUPERNOVA_BROWSER_TESTS=1` |
| Health Server (`/health`, `/health/live`, `/health/ready`) | Implemented | Unit JSON/uptime tests + Docker container live probe |
| Persistence (`adapters/postgres`, `adapters/pgvector`, `adapters/sqlite`, `adapters/redis`) | Implemented | Offline driver/query tests (`pgvector` & live PostgreSQL migrations deferred to PRD B) |

---

## Deferred to PRD B (External Live Integrations)

The following items are accepted (`ACEITO`) in [audit/STATUS_2026-11.md](audit/STATUS_2026-11.md) and scoped out of offline stabilization:

1. **Live PostgreSQL & pgvector integration tests** (findings `2.11`, `REQ-PROD-05`, `2.12`) — schema migration and vector queries against a running PostgreSQL instance
2. **Real Chromium / Playwright browser E2E suite** (`3.4`, `SUPERNOVA_BROWSER_TESTS=1`) — automated CI stage with Playwright + Chromium installed
3. **Live external provider & messaging API smoke tests** (`2.1`, `2.2`) — real token E2E validation beyond offline mocked/loopback HTTP tests
4. **Coverage expansion toward 85%** — raising coverage on low-hit network/provider modules (`minimax`, `pgvector`, `channel/registry`, adapters) once live harnesses exist in PRD B


## Closed-Group Channel Support (v0.4.0)

| Channel | Support | Notes |
|---|---|---|
| Telegram | Supported | Access, budget, capabilities, rate limit, `/eu`, `/uso`, `/acesso`, `/teto`, `/auditoria`, `/eu` chat discovery, leave unauthorized groups |
| Discord | Supported | Same closed-group pipeline for DMs and servers; `/eu` chat discovery |
| Slack | Experimental | Not covered by closed-group end-to-end tests |
| Matrix | Experimental | Not covered by closed-group end-to-end tests |
| Lark | Experimental | Not covered by closed-group end-to-end tests |
| Google Chat | Experimental | Not covered by closed-group end-to-end tests |
| Mattermost | Experimental | Not covered by closed-group end-to-end tests |
| WeChat Work | Experimental | Not covered by closed-group end-to-end tests |
| WhatsApp | Experimental | Not covered by closed-group end-to-end tests |
