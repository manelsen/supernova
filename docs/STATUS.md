# Supernova Status

**Last updated:** 2026-11-22
**Version:** `0.4.0` (`gleam.toml`)
**Toolchain:** Erlang `28.5.0.8` / Gleam `1.19.2` (`.tool-versions`)

What is open, and in what order, is in [PENDENCIAS.md](PENDENCIAS.md). This page only records what is true today.

## Quality gates

| Check | Result | Notes |
|---|---|---|
| `gleam format --check src test` | Passing | |
| `gleam build --warnings-as-errors` | Passing | Dependencies (`gleam_hackney`, `wisp`) still use the deprecated `http.Header`; that warning comes from them, not from Supernova. |
| `make test` | `2503` passed, `0` failed | Offline: no test calls a real model. Live Chromium tests are opt-in (`SUPERNOVA_BROWSER_TESTS=1`). |
| `make coverage` | `79.82%` (`14349/17976` lines) | CI gate: 79%. Raised by risk first ([PENDENCIAS](PENDENCIAS.md) 3.5). |
| Computer service tests | `14` passed | Inside the image, on gVisor and on runc; CI runs them on runc (`.github/workflows/computador.yml`). |
| Audit (`audit/STATUS_2026-11.md`) | 20 resolved, 5 accepted, 0 open | The accepted Postgres items lost their object when Postgres was removed (PR #33). |

## Channels

| Channel | Status |
|---|---|
| Telegram | Supported: closed group, commands, buttons, streaming, typing, threads, chunking |
| WhatsApp | Supported through GOWA: closed group, private chats only (groups off by default, `whatsapp.allow_groups`), every kind of media read, voice answers, account-down alert with a pairing code on Telegram. Same agent as on another channel after `/vincular`. |
| Discord | Supported since PRD-D: gateway with resume and readiness, closed group in private chats and authorized servers, slash commands with suggestions by role, buttons that edit their message, every kind of media read, agenda in private. Verified against a local gateway and API and the anonymized captures of February; not yet with a real bot ([DISCORD.md](operations/DISCORD.md)). Voice answers are not supported. |
| Slack, Matrix, Lark, Google Chat, Mattermost, WeChat Work | Send only, experimental: they do not receive messages, are not behind the closed group and have no end-to-end tests. Supernova warns at boot. |

On WhatsApp, the agent opens what the person sends (PRD-A): images go to its model with audio description rules; voice notes, videos, documents and animated stickers are read into text by Gemini before the turn and stay in the memory; location, contact and poll become text. `/voz` answers with voice notes, `/transcricao` gives the transcription back, `/curto`, `/longo` and `/cego` set the detail. Telegram reads the same media (photos, voice, audio, video, documents, stickers; Lottie stickers become a note; files over the Bot API's 20 MB become a note); voice answers are WhatsApp only.

## Runtime

| Component | Status |
|---|---|
| Kernel: scheduler, budget, workspace, capabilities, ledger, audit, syscall gateway | In use |
| Closed group: access, rate limit, per-person and instance ceilings, lanes per chat | In use in the pilot |
| One agent per person: birth, name, journal, reflection, drift, forgetting, incidents | In use in the pilot. With one person, drift never reaches its threshold; the decided fix is in [PENDENCIAS](PENDENCIAS.md) 3.1. |
| Agenda | In use in the pilot |
| LLM: 11 providers, circuit breaker, failover cooldown, retry | In use (Mistral serving DeepSeek V4.1 Flash) |
| Images in the conversation (from tools) | In use (OpenAI-compatible providers; the Anthropic encoder ignores images) |
| The agent's computer (`computador`) | Phase 1 in use: gVisor, shell, browser, vision, host firewall. Phase 2 is decided. |
| Conversation history | Kept whole on disk, per person and chat, and reloaded after a restart. The model sees the last 100 messages; the agent searches the rest with `buscar_conversa`. |
| Health endpoints | Working |
| Metrics and tracing | Instrumented, but nothing shows in the pilot ([OBSERVABILITY.md](operations/OBSERVABILITY.md)) |
| Persistence | Files under `/data` (ledger, access, agents' selves, workspaces). There is no database. |
