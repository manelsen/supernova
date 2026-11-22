# Observability

How to see what Supernova is doing, and what is still missing. The maintainer decided on 22/11/2026 that observability should be total. The gaps listed under [What does not work yet](#what-does-not-work-yet) are tracked in [`docs/PENDENCIAS.md`](../PENDENCIAS.md), section 3.4.

## Health endpoints

The health server listens on port **8080** inside the container. The port is not published to the host. Query it with `docker exec`, or publish it yourself in a compose override.

| Endpoint | Answers | Used by |
|---|---|---|
| `GET /health` | `{"status":"ok","uptime_seconds":N}` | People |
| `GET /health/live` | `ok` | The compose healthcheck |
| `GET /health/ready` | Status, uptime and the names of the enabled channels. Every channel is listed with `ready: true` and `error: null`: the endpoint does not check channel state, and it always answers 200. | People. For channel errors, read the logs. |

```sh
docker exec supernova wget -qO- http://127.0.0.1:8080/health/ready
```

A 200 from `/health/ready` shows that the process is up and which channels are configured. It does not show that a channel works.

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

- **`/health/ready` does not check channels.** It lists the configured channels as ready and always answers 200.
- **`/metrics` is empty in the pilot.** It answered 200 with an empty body after an hour of conversation. The cause has not been investigated.
- **No spans in the logs.** The tracer starts at boot, but no `llm.chat` or `tool.execute` span reached the pilot's logs.
- **No exporter.** There is no Prometheus scrape configuration, no OTLP collector and no dashboards.
- **Modules that nothing uses.** `core/telemetry`, `core/dashboard` and `core/alerts/actor` are not used outside their own modules.
- **Performance never measured.** The benchmarks in `test/bench/` and the load test in `tests/load/` (`run_load_tests.sh`) exist. The targets from `docs/prd/production-ready-v1.md` (100 concurrent users, p99 under 2 s, under 1% errors) have never been checked.
