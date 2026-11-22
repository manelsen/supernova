# Observability

How to see what Supernova is doing, and what is still missing. The maintainer decided on 22/11/2026 that observability should be total. The gaps listed under [What does not work yet](#what-does-not-work-yet) are tracked in [`docs/PENDENCIAS.md`](../PENDENCIAS.md), section 3.4.

## Health endpoints

The health server listens on port **8080** inside the container. The port is not published to the host. Query it with `docker exec`, or publish it yourself in a compose override.

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
| `/data/agents/<principal>/self/` | Per agent: `journal.jsonl` (turns not yet reflected), `experience.jsonl`, `pressure.jsonl`, `biography.jsonl`, `agenda.json`, and the core (`core.md`, `core.json`). |
| `/uso`, `/uso todos` | Spending per person, from the ledger (admins see everyone). |
| `/auditoria [n]` | The last audit events (20 by default). Admins only. |

## Metrics and tracing

The code is there, but the pilot shows nothing:

- The executor records `llm_requests_total`, latency and complexity histograms, and opens `llm.chat` and `tool.execute` spans.
- Sub-agents count `agents_spawned_total` and `agents_stopped_total`.
- `GET /metrics` serves the Prometheus text format.
- Spans are written to stdout. There is no OTLP export.

## What does not work yet

- **Readiness only probes Telegram.** The other channels count as ready once they start.
- **`/metrics` is empty in the pilot.** It answered 200 with an empty body after an hour of conversation. The cause has not been investigated.
- **No spans in the logs.** The tracer starts at boot, but no `llm.chat` or `tool.execute` span reached the pilot's logs.
- **No exporter.** There is no Prometheus scrape configuration, no OTLP collector and no dashboards.
- **Modules that nothing uses.** `core/telemetry`, `core/dashboard` and `core/alerts/actor` are not used outside their own modules.
- **Performance never measured.** The benchmarks in `test/bench/` and the load test in `tests/load/` (`run_load_tests.sh`) exist. The targets from `docs/prd/production-ready-v1.md` (100 concurrent users, p99 under 2 s, under 1% errors) have never been checked.
