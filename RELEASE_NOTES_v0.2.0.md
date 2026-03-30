# Release Notes — Supernova 0.2.0

## Highlights

Supernova 0.2.0 is a major release that delivers **full multi-channel parity**: Discord, Telegram, Slack, and Matrix now share identical session management, command handling, interactive model selection, and native streaming behaviour. Five additional channels (Google Chat, Lark, Mattermost, WeChat Work, WhatsApp) are also included as first-class adapters.

---

## What's Changed

### Core Foundations

- **Configuration system** (`config.gleam`) — YAML-decodable config for 9 channels and 8 LLM providers with full `SUPERNOVA_*` env-var overrides
- **Rich Port contract** (`port.gleam`, `chunking.gleam`) — `ChannelReply` gains `thread_id`, `typing`, `edit_message_id`, and `media: []ChannelMedia`; new streaming types (`ChannelStreamEvent`, `ChannelHandlerResult`); `ChannelInteractiveReply` with text/button/select blocks
- **Session persistence** (`session/server.gleam`, `session/supervisor.gleam`) — per-conversation OTP actors storing message history; `SessionSupervisor` registry + factory; `/model` selections persist across the session
- **Multi-provider LLM client** (`llm/client.gleam`, `ollama.gleam`, `providers_info.gleam`) — unified `chat()` / `stream_chat()` for OpenAI, Anthropic, OpenRouter, OpenCodeZen, Zhipu, ZhipuCoding, MiniMax, and Ollama; deterministic mock mode for testing

### Executor & Tools

- **Streaming executor** (`core/executor.gleam`) — real-time `ChannelStreamEvent` emission; cooperative budget policy with pause/resume; checkpoint-tested pause cycles
- **5 built-in tools** with Erlang FFI:
  - `browser` — headless Playwright automation via `supernova_browser_ffi.erl`
  - `canvas` — image/diagram rendering
  - `gateway` — authenticated external HTTP calls
  - `github` — GitHub REST API (issues, PRs, file contents)
  - `process` — OS process execution with stdout/stderr capture via `supernova_process_ffi.erl`

### Channel Adapters

#### Discord
- Gateway event decoding (`MESSAGE_CREATE`, `INTERACTION_CREATE`, `READY`, heartbeats)
- REST client with `send_message`, `edit_message`, `delete_message`, `send_typing`
- Rate-limit 429 handling with `retry-after`
- Full OTP router with `SessionSupervisor`; removed legacy `discord_session.gleam`

#### Telegram
- Full adapter with polling worker
- Parses `Message`, `CallbackQuery`, `PollAnswer`, `MessageReaction`
- Inline keyboard callbacks for model picker
- Full OTP router with `SessionSupervisor`; removed legacy `telegram_session.gleam`

#### Slack (US-027, US-028)
- **Native progressive feedback** — `NativeStream` mode (DM/thread) uses `chat.startStream → chat.appendStream → chat.stopStream`; `MessageUpdateFallback` mode (public channels) uses `chat.postMessage + chat.update`
- Full session parity with Discord/Telegram via rewritten OTP router
- `/help`, `/start`, `/status`, `/model` all functional; interactive Block Kit model picker

#### Matrix (US-029)
- Streaming via Matrix CS API edit protocol (`m.room.message` with `m.relates_to` / `rel_type: m.replace`)
- Full event parsing (`m.room.message`, `m.room.member`, `m.reaction`)
- Full OTP router with session supervision; per-room isolation
- `/help`, `/start`, `/status`, `/model` all functional

#### Google Chat, Lark, Mattermost, WeChat Work, WhatsApp
- Each follows the standard adapter pattern: `parse_event()`, `send_reply()`, `resolve_session_id()`
- Webhook-based (Google Chat, WeChat Work) or REST-based (Lark, Mattermost, WhatsApp)
- All support `HandleInboundForHandler` for streaming and optional `SessionSupervisor`

### Bootstrap & Runtime

- **Shared command router** (`channel_common_router.gleam`) — single source of truth for `/help`, `/start`, `/status`, `/model` across all channels
- **Channel registry** (`channel/registry.gleam`) — central orchestrator for startup, streaming dispatch, and typing keepalive
- **`supernova.gleam`** — full entry point wiring all components together
- **Project wizard** (`wizard.gleam`) — interactive multi-step setup with provider/model selection and credential configuration

---

## User Stories Completed

| ID | Description | Status |
|----|-------------|--------|
| US-001 | Connect channel bootstrap to main | ✅ |
| US-002 | Connect port adapter end-to-end | ✅ |
| US-003 | Create native Matrix adapter | ✅ |
| US-004 | Create native Slack adapter | ✅ |
| US-005 | Create WhatsApp adapter | ✅ |
| US-006 | Create Google Chat, Lark, Mattermost, WeChat Work adapters | ✅ |
| US-007 | Full Discord interactions wiring | ✅ |
| US-008 | Full Telegram callbacks/inline wiring | ✅ |
| US-009 | Real browser tool (current) | ✅ |
| US-010 | Sessions with yield | ✅ |
| US-011 | Process tool | ✅ |
| US-012 | GitHub tool | ✅ |
| US-013 | Canvas tool | ✅ |
| US-014 | Gateway tool | ✅ |
| US-015 | Integrate tool loop into channel runtime | ✅ |
| US-016 | Evolve ChannelReply to rich payload | ✅ |
| US-017 | Implement executable UX commands | ✅ |
| US-018 | Provider/model selection via buttons with persistence | ✅ |
| US-019 | Agent bootstrapping per session | ✅ |
| US-020 | Add thread_id to ChannelReply | ✅ |
| US-021 | Typing indicators in contract and implementation | ✅ |
| US-022 | Intelligent chunking by channel limit | ✅ |
| US-023 | Unify minimal session with rich session | ✅ |
| US-024 | Align config providers with effective runtime | ✅ |
| US-025 | E2E tests: port → adapter → executor → channel | ✅ |
| US-026 | Real streaming per channel | ✅ |
| US-027 | Native progressive feedback on Slack | ✅ |
| US-028 | Full Slack parity with Discord/Telegram | ✅ |
| US-029 | Full Matrix parity with Discord/Telegram | ✅ |

---

## Upgrade Notes

- The `SessionSupervisor` is now shared across all channels — sessions created with previous versions are not migrated
- `discord_session.gleam` and `telegram_session.gleam` have been removed; use `SessionSupervisor` instead
- `MatrixConfig` now includes `homeserver_url: Option(String)` — set `SUPERNOVA_MATRIX_HOMESERVER_URL` if not in YAML

---

## Validation

```bash
gleam format --check src test  # ✓ clean
gleam build                    # ✓ builds
gleam test                     # ✓ 1640 passed
```
