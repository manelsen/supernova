# Observability

How to see what Supernova is doing, and what is still missing. The maintainer decided on 22/11/2026 that observability should be total. The gaps listed under [What does not work yet](#what-does-not-work-yet) are tracked in [`docs/PENDENCIAS.md`](../PENDENCIAS.md), section 3.4.

## Health endpoints

The health server listens on port **8080** inside the container. The port is not published to the host. Query it with `docker exec`; Prometheus reaches it through the compose network.

| Endpoint | Answers | Used by |
|---|---|---|
| `GET /health` | `{"status":"ok","uptime_seconds":N}` | People |
| `GET /health/live` | `ok` | The compose healthcheck |
| `GET /health/ready` | Status, uptime and each enabled channel with `ready` and `error`. 200 with `"status":"ok"` when every channel is ready; 503 with `"status":"degraded"` otherwise. | People and external monitors |

```sh
docker exec supernova curl -sS -i http://127.0.0.1:8080/health/ready
```

What `ready` means for each channel:

- **Telegram** reports every `getUpdates`. A failed poll makes it not ready, with the error (for example `telegram api error 401: Unauthorized` for a bad token), until the next poll succeeds; failed polls are retried with backoff from 1 s to 30 s. A minute with no successful poll, for example because the polling process died, also makes it not ready.
- **A channel that failed to start**, or that has `enabled: true` with a required setting missing (for example `enabled but missing token`), is listed as not ready, with the reason.
- **The other channels** only report that they started. A Discord gateway that disconnects later still shows as ready.

The compose healthcheck uses `/health/live`, so a channel that is down does not restart the container.

The computer (`computador`) has its own `GET /health` on port 7070, and the compose healthcheck uses it. See [COMPUTADOR.md](COMPUTADOR.md).

## Logs

```sh
docker compose logs -f supernova
docker compose logs -f computador
```

Supernova logs the channel bootstrap, configuration warnings (experimental channels, unknown capabilities) and errors.

## Spending and audit

These are the most complete record of what happened. All of them live in the `supernova_data` volume.

| Where | What |
|---|---|
| `/data/ledger/<date>.jsonl` | One line per LLM charge: who (`principal_id`), provider, model, prompt and completion tokens, cost in USD. The daily and instance ceilings are computed from it. |
| `/data/agents/<principal>/conversations/` | One file per chat, `<session>.jsonl`: the most recent messages of the conversation (`conversation.history_limit`, 40 by default), reloaded after a restart. `/esquecer` deletes them. |
| `/data/agents/<principal>/self/` | Per agent: `journal.jsonl` (turns not yet reflected), `experience.jsonl`, `pressure.jsonl`, `biography.jsonl`, `agenda.json`, and the core (`core.md`, `core.json`). |
| `/uso`, `/uso todos` | Spending per person, from the ledger (admins see everyone). |
| `/auditoria [n]` | The last audit events (20 by default). Admins only. |

## Metrics and tracing

```sh
docker exec supernova curl -sS http://127.0.0.1:8080/metrics
docker compose logs supernova | grep '\[TRACE\]'
```

`GET /metrics` serves the Prometheus text exposition format: one `# TYPE` line per family, histograms as cumulative `_bucket` series ending in `le="+Inf"` plus `_sum` and `_count`, escaped label values. Durations are in seconds. The counters start from zero at every restart, as Prometheus expects. At boot, every series Supernova knows in advance is published at zero: per channel (messages, gate decisions, turn outcomes, send errors, polling errors, full queues), the default model's requests, tokens and cost, and the agenda outcomes. Prometheus's `increase` only counts what comes after a series' first sample, so without this the first message after each restart would not show on the dashboard. A series that only appears later, such as another model chosen with `/model` or an error type, still loses its first event.

| Metric | Type | Labels |
|---|---|---|
| `llm_requests_total` | counter | `provider`, `model`, `status` (`success`, `error`), `error_type` on errors |
| `llm_request_duration_seconds` | histogram | `provider`, `model` |
| `tool_executions_total` | counter | `tool`, `status` |
| `tool_execution_duration_seconds` | histogram | `tool` |
| `complexity_score` | histogram | `tier` |
| `complexity_selected_tier_total` | counter | `tier`, `model_used` |
| `agents_spawned_total`, `agents_stopped_total` | counter | `status` on stops |
| `agents_active` | gauge | |
| `channel_messages_total` | counter | `channel`, `kind` (`message`, `interaction`) |
| `turn_duration_seconds` | histogram | `channel`, `outcome` (`replied`, `streamed`, `stream_timeout`, `send_error`, `ignored`, `handler_error`) |
| `channel_send_errors_total` | counter | `channel`, `error` (`send_failed`, `rate_limited`, `not_connected`, `other`) |
| `chat_lane_rejected_total` | counter | `channel` |
| `channel_poll_errors_total` | counter | `channel` |
| `gate_decisions_total` | counter | `channel`, `decision` (`allowed`, `denied`, `chat_denied`, `rate_limited`, `budget`, `instance_cap`, `fail_closed`, `eu`, `command`, `missing_sender`) |
| `llm_tokens_total` | counter | `kind` (`prompt`, `completion`), `provider`, `model` |
| `llm_cost_usd_micros_total` | counter | `provider`, `model`. Cost in millionths of a dollar. |
| `agenda_runs_total` | counter | `outcome` (`ran`, `dropped`, `missed`, `sweep_crashed`) |

A reply that does not reach the person is counted in `channel_send_errors_total` and logged as `warn: reply not delivered channel=... error=...`.

Spans are written to stdout as `[TRACE] span started/ended` lines: `llm.chat` for every model call (with its duration and status) and `tool.execute` for every tool call. There is no OTLP export.

The circuit breaker opens for a provider after 5 consecutive failures that mean the provider is unavailable (network errors, 5xx, 429) and blocks its calls for 30 s; a request error (4xx) does not count. The person sees "o provedor do modelo ficou fora por um tempo, depois de várias falhas seguidas".

## Prometheus and Grafana

Two optional containers turn `/metrics` into history and charts:

- **Prometheus** reads `/metrics` every 15 s and keeps what it reads for 90 days (at most 2 GB). Since the counters start from zero at every restart, Prometheus is what lets you see a week or a month.
- **Grafana** draws charts from Prometheus. It starts with a ready dashboard, **Supernova**, which is also its home page.

They are off unless the `observabilidade` profile is on. In `.env`, profiles are separated by commas:

```sh
COMPOSE_PROFILES=computador,observabilidade
```

Then `docker compose up -d`. Each container is limited to 512 MB of memory.

Both listen only on the host's loopback (`127.0.0.1:3000` for Grafana, `127.0.0.1:9090` for Prometheus), never on the public network. From your own computer, open an SSH tunnel to the server and keep it open:

```sh
ssh -N -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 user@server
```

Then open <http://localhost:3000> in the browser. The user is `admin`; the password is `SUPERNOVA_GRAFANA_PASSWORD` from `.env`, or `admin` if it is not set, and Grafana asks for a new one on the first login. Prometheus itself (<http://localhost:9090>) is only needed to write your own queries.

The dashboard has four parts. The time range in the top right corner (24 hours by default) applies to all of them.

| Part | Shows |
|---|---|
| Summary | Whether Supernova is up, messages received, response time (p95: 95% of turns finished within it), cost, replies that did not reach the person, and failed model calls, all for the chosen range |
| Conversation | Messages per channel, response time (p50 and p95), the gate's decisions, and how each turn ended |
| Model and cost | Cost and tokens per hour, model calls by result, and the provider's latency |
| Problems and routine | Replies not delivered, channel polling errors, messages refused because the chat's queue was full, agenda runs, and tools used and failed |

The panels count with Prometheus's `increase`, which estimates from samples taken every 15 s. Over a short range, or right after a restart, the numbers can be off by a little; the ledger (`/uso`) is the exact record of spending.

The dashboard is provisioned from `monitoring/grafana/dashboards/supernova.json` and cannot be changed from Grafana's screen. To keep your own changes, save a copy of the dashboard ("Save as") in another folder.

## What does not work yet

- **Readiness only probes Telegram.** The other channels count as ready once they start.
- **No OTLP export.** Spans only go to stdout; there is no collector and no trace viewer.
- **No alerts.** Grafana shows the problems but does not warn anyone yet.
- **Modules that nothing uses.** `core/telemetry`, `core/dashboard` and `core/alerts/actor` are not used outside their own modules.
- **Performance never measured.** The benchmarks in `test/bench/` and the load test in `tests/load/` (`run_load_tests.sh`) exist. The targets from `docs/prd/production-ready-v1.md` (100 concurrent users, p99 under 2 s, under 1% errors) have never been checked.
