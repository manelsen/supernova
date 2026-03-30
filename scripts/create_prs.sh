#!/usr/bin/env bash
# Run this script to open all 8 release PRs.
# Each PR targets the previous one, forming a reviewable stack.
set -e

# ──────────────────────────────────────────────────────────────
# PR 1 — Core foundations
# ──────────────────────────────────────────────────────────────
gh pr create \
  --base main \
  --head release/01-core-foundations \
  --title "feat(core): config, port types, session management, and LLM providers" \
  --body "## What this PR does

Establishes the Supernova runtime foundation: rich Port contract, complete
config system for 9 channels and 8 LLM providers, per-conversation session
persistence, and a multi-provider LLM client.

## Commits

| Hash | Subject |
|------|---------|
| \`496ed9b\` | feat(config): full channel and LLM provider configuration system |
| \`744bd2a\` | feat(port): rich message types, streaming protocol, and response chunking |
| \`d52c3a2\` | feat(session): persistent session server and supervisor for LLM history |
| \`985b1a7\` | feat(llm): multi-provider client, Ollama backend, and providers catalog |

## Details

**config.gleam**
- 9 channels: Discord, Telegram, Slack, Matrix (\`homeserver_url\`), Lark,
  Google Chat (\`webhook_url\`), Mattermost (\`base_url\`), WeChat Work, WhatsApp (\`bridge_url\` + \`device_id\`)
- 8 LLM providers: OpenAI, Anthropic, OpenRouter, OpenCodeZen, Zhipu, ZhipuCoding, MiniMax, Ollama + \`mock\`
- YAML-decodable; all fields overridable via \`SUPERNOVA_*\` env vars

**port.gleam + chunking.gleam**
- \`ChannelReply\` gains: \`thread_id\`, \`typing\`, \`edit_message_id\`, \`media: []ChannelMedia\`
- New types: \`ChannelStreamEvent\` (Update/Complete/Failure), \`ChannelHandlerResult\` (Immediate/Stream)
- \`ChannelInteractiveReply\` with text, button, and select blocks (Block Kit / inline keyboards)
- \`ChannelInteractionMessage\` + \`ChannelInteractionEvent\` for component callbacks
- Builders: \`reply()\`, \`reply_thread()\`, \`button()\`, \`select_option()\`
- \`chunking.split_reply()\` with per-channel message-length limits

**session/server.gleam + session/supervisor.gleam**
- \`SessionServer\`: OTP actor per conversation storing message history and full \`ProviderConfig\` override
- Handlers: \`GetHistory\`, \`AppendMessage/s\`, \`GetLLMConfig\`, \`SetLLMConfig\`, \`ClearLLMConfig\`
- \`SessionSupervisor\`: registry + factory — \`get_or_start(id)\` creates or reuses; \`stop()\` tears down all children
- Config override makes \`/model\` selection persist across the whole session

**llm/client.gleam + ollama.gleam + providers_info.gleam**
- \`chat()\` and \`stream_chat()\` normalised over all providers (OpenAI-compatible)
- Mock mode (\`name: \"mock\"\`): deterministic local responses; magic strings \`[echo-model]\`, \`[stream-error]\`, \`[stream-timeout]\` for tests
- Ollama: full \`/api/chat\` HTTP adapter with streaming
- \`providers_info\`: \`models_for_provider()\` and \`provider_display_name()\` powering the \`/model\` picker UI

## Test plan
- [ ] \`gleam format --check src test\` — clean
- [ ] \`gleam test\` — 1640 passed, no failures
- [ ] \`test/config/config_test.gleam\` — all channel + provider encode/decode
- [ ] \`test/channel/session_test.gleam\`, \`test/core/session/supervisor_test.gleam\`
- [ ] \`test/llm/provider_test.gleam\` — mock mode, streaming, all providers
- [ ] \`test/channel/chunking_test.gleam\`"

echo "PR 1 created."

# ──────────────────────────────────────────────────────────────
# PR 2 — Executor + tools
# ──────────────────────────────────────────────────────────────
gh pr create \
  --base release/01-core-foundations \
  --head release/02-executor-tools \
  --title "feat(executor): streaming pipeline, budget policy, and 5 built-in tools" \
  --body "## What this PR does

Adds the streaming executor pipeline, cooperative budget policy, and five
built-in tools (browser, canvas, gateway, github, process) with Erlang FFI
where OS integration is needed.

**Depends on:** release/01-core-foundations

## Commits

| Hash | Subject |
|------|---------|
| \`f7c5b8d\` | feat(executor): streaming pipeline, budget policy, and 5 built-in tools |

## Details

**core/executor.gleam**
- \`run_stream()\` dispatches LLM call and emits \`ChannelStreamEvent\` in real time
- \`run_stream_mock()\` for deterministic tests (\`[echo-model]\`, \`[stream-error]\`, \`[stream-timeout]\`)
- \`YieldConfig\` gains: \`timeout_ms\`, \`started_at_ms\`, \`budget_policy\`, \`budget_agent_id\`
- Budget policy: executor pauses cooperatively when resource limits are reached
- Checkpoint: pause/resume cycles validated in \`executor_checkpoint_test.gleam\`

**tools/browser.gleam** + \`src/supernova_browser_ffi.erl\`
- Headless browser automation via Playwright; FFI bridges Gleam → Erlang → Node.js

**tools/canvas.gleam** — image/diagram rendering

**tools/gateway.gleam** — authenticated HTTP calls to external APIs

**tools/github.gleam** — GitHub REST API (issues, PRs, file contents)

**tools/process.gleam** + \`src/supernova_process_ffi.erl\`
- OS process execution with stdout/stderr capture via Erlang FFI

## Test plan
- [ ] \`gleam test\` — 1640 passed, no failures
- [ ] \`test/core/executor_test.gleam\` — streaming, mock magic strings, budget pause
- [ ] \`test/core/checkpoint/executor_checkpoint_test.gleam\` — pause/resume cycles
- [ ] \`test/tools/\` — all 5 tool test files"

echo "PR 2 created."

# ──────────────────────────────────────────────────────────────
# PR 3 — Discord + Telegram adapters
# ──────────────────────────────────────────────────────────────
gh pr create \
  --base release/02-executor-tools \
  --head release/03-discord-telegram \
  --title "feat(adapters): Discord gateway/REST and Telegram polling with streaming routers" \
  --body "## What this PR does

Implements the Discord and Telegram channel adapters — event parsing, API
clients, and full streaming routers. Removes the legacy per-channel session
managers in favour of the shared \`SessionSupervisor\`.

**Depends on:** release/02-executor-tools

## Commits

| Hash | Subject |
|------|---------|
| \`41e02dd\` | feat(adapters/discord): gateway events, REST client, and full streaming router |
| \`c26179b\` | feat(adapters/telegram): full adapter with polling and streaming router |

## Details

**discord_events.gleam**
- Decodes all gateway payloads: \`MESSAGE_CREATE\`, \`INTERACTION_CREATE\`, \`READY\`, heartbeats
- Extracts channel, user, content, and component interaction data

**discord_rest.gleam**
- \`send_message()\`, \`edit_message()\`, \`delete_message()\` via Discord REST API
- \`send_typing()\` — POST \`/channels/{id}/typing\` for live typing indicator
- Rate-limit 429 handling with \`retry-after\`

**discord_router.gleam**
- Removes \`discord_session.gleam\`; uses \`SessionSupervisor\` for multi-turn memory
- \`start_with_session_supervisor(supervisor, llm_config) → DiscordRouter\`
- \`route_inbound_for_handler(router, inbound, stream_events)\` for streaming dispatch
- \`HandleInboundForHandler\` message variant added alongside legacy \`HandleInbound\`

**telegram.gleam**
- Parses: \`Message\`, \`CallbackQuery\`, \`PollAnswer\`, \`MessageReaction\`
- Normalises to \`ChannelMessage\` / \`ChannelInteractionMessage\`
- Inline keyboard callbacks handled for model picker selections

**telegram_router.gleam**
- Same refactor pattern as Discord: \`SessionSupervisor\`, \`HandleInboundForHandler\`
- Removes \`telegram_session.gleam\`

**Deleted:** \`discord_session.gleam\`, \`telegram_session.gleam\` and their test files

## Test plan
- [ ] \`gleam test\` — 1640 passed, no failures
- [ ] \`test/adapters/discord_events_test.gleam\`, \`discord_rest_test.gleam\`, \`discord_channel_test.gleam\`
- [ ] \`test/adapters/telegram_test.gleam\`, \`telegram_channel_test.gleam\`"

echo "PR 3 created."

# ──────────────────────────────────────────────────────────────
# PR 4 — Slack parity (US-027, US-028)
# ──────────────────────────────────────────────────────────────
gh pr create \
  --base release/03-discord-telegram \
  --head release/04-slack-parity \
  --title "feat(adapters/slack): native streaming progress and full session parity (US-027, US-028)" \
  --body "## What this PR does

Closes **US-027** (Slack native progressive feedback) and **US-028** (Slack full
parity with Discord and Telegram) — Slack now has the same session management,
command handling, interactive model picker, and streaming behaviour as Discord.

**Depends on:** release/03-discord-telegram

## Commits

| Hash | Subject |
|------|---------|
| \`c867d96\` | feat(adapters/slack): native streaming progress and full session parity (US-027, US-028) |

## Details

### US-027 — Native progressive feedback (slack_adapter.gleam)

\`ProgressMode\` detection:
- **\`NativeStream\`** (DM/thread): uses \`chat.startStream\` → \`chat.appendStream\` → \`chat.stopStream\`
- **\`MessageUpdateFallback\`** (public channel): \`chat.postMessage\` + \`chat.update\` edits

\`progress_mode(reply)\` detects capability from \`channel_id\` prefix (\`\"D\"\` = DM) and \`thread_target\`.

Block Kit payload builders for buttons, select menus, and text sections.

### US-028 — Full session parity (slack_router.gleam)

Router rewritten as a full OTP actor (previously a thin \`generic_channel_router\` wrapper):
- \`start_with_session_supervisor(supervisor, llm_config) → SlackRouter\`
- \`route_inbound_for_handler(router, inbound, stream_events)\` — was missing, blocking streaming
- \`HandleInboundForHandler\` message variant added
- \`resolve_session(\"slack:{channel_id}:{user_id}\")\` — multi-session isolation
- \`/help\`, \`/start\`, \`/status\`, \`/model\` commands fully functional
- \`/model\` returns interactive Block Kit picker (Slack added to \`channel_supports_interactions\`)
- \`picker_model_select\` callback persists \`ProviderConfig\` in \`SessionSupervisor\`

## Test plan
- [ ] \`gleam test\` — 1640 passed, no failures
- [ ] \`test/adapters/slack_adapter_test.gleam\` — progress mode detection, payload builders
- [ ] \`test/adapters/slack_integration_test.gleam\` — end-to-end event flow
- [ ] \`test/channel/registry_test.gleam\`:
  - \`e2e_slack_help_command_routes_from_inbound_to_reply_test\`
  - \`e2e_slack_start_command_returns_session_bootstrapped_test\`
  - \`e2e_slack_model_command_returns_interactive_picker_test\`
  - \`e2e_slack_model_selection_persists_for_session_test\`"

echo "PR 4 created."

# ──────────────────────────────────────────────────────────────
# PR 5 — Matrix parity (US-029)
# ──────────────────────────────────────────────────────────────
gh pr create \
  --base release/04-slack-parity \
  --head release/05-matrix-parity \
  --title "feat(adapters/matrix): streaming edit replies and full session parity (US-029)" \
  --body "## What this PR does

Closes **US-029** (Matrix full parity with Discord and Telegram) — Matrix now
has a full OTP router with session supervision, streaming via in-place edits,
and all standard commands.

**Depends on:** release/04-slack-parity

## Commits

| Hash | Subject |
|------|---------|
| \`a97232a\` | feat(adapters/matrix): streaming edit replies and full session parity (US-029) |

## Details

### matrix_adapter.gleam

Streaming via Matrix CS API edit protocol:
1. Send initial message → \`PUT /rooms/{roomId}/send/m.room.message/{txnId}\` — returns \`event_id\`
2. \`send_reply_with_event_id()\` captures the \`event_id\` for subsequent edits
3. Each \`StreamUpdate\` edits the message via \`m.relates_to\` / \`rel_type: m.replace\`
4. \`StreamComplete\` with identical content is deduplicated (no double-edit)

Full event parsing: \`m.room.message\`, \`m.room.member\`, \`m.reaction\`

### matrix_router.gleam

Router rewritten as a full OTP actor (previously a thin wrapper):
- \`start_with_session_supervisor(supervisor, llm_config) → MatrixRouter\`
- \`route_inbound_for_handler(router, inbound, stream_events)\` for streaming dispatch
- \`HandleInboundForHandler\` message variant added
- \`resolve_session(\"matrix:{roomId}:{userId}\")\` — per-room isolation
- \`/help\`, \`/start\`, \`/status\`, \`/model\` commands fully functional

### Config change

\`MatrixConfig\` gains \`homeserver_url: Option(String)\`
Env override: \`SUPERNOVA_MATRIX_HOMESERVER_URL\`

## Test plan
- [ ] \`gleam test\` — 1640 passed, no failures
- [ ] \`test/adapters/matrix_adapter_test.gleam\` — event parsing, send, edit
- [ ] \`test/adapters/matrix_integration_test.gleam\` — end-to-end event flow
- [ ] \`test/channel/registry_test.gleam\`:
  - \`e2e_matrix_help_command_routes_from_inbound_to_reply_test\`
  - \`e2e_matrix_start_command_returns_session_bootstrapped_test\`
  - \`e2e_matrix_follow_up_uses_session_history_test\`"

echo "PR 5 created."

# ──────────────────────────────────────────────────────────────
# PR 6 — Other adapters
# ──────────────────────────────────────────────────────────────
gh pr create \
  --base release/05-matrix-parity \
  --head release/06-adapters-others \
  --title "feat(adapters): Google Chat, Lark, Mattermost, WeChat Work, and WhatsApp" \
  --body "## What this PR does

Adds the remaining five channel adapters. Each follows the same pattern:
\`parse_event()\`, \`send_reply()\`, \`resolve_session_id()\`, and a thin router
wrapping \`channel_common_router\`.

**Depends on:** release/05-matrix-parity

## Commits

| Hash | Subject |
|------|---------|
| \`7001842\` | feat(adapters): Google Chat, Lark, Mattermost, WeChat Work, and WhatsApp |

## Details

**google_chat_adapter / google_chat_router**
- Webhook-based: validates \`X-Goog-Signature\`, sends via \`webhook_url\` POST
- Parses card click events and message events

**lark_adapter / lark_router**
- Open API v3: Bearer token via \`base_url/im/v1/messages\`
- Parses \`message.receive\` events with \`tenant_key\` and \`user_id\` extraction

**mattermost_adapter / mattermost_router**
- REST API: POST \`/api/v4/posts\` with \`base_url\` + \`access_token\`
- Parses \`posted\` events from slash commands and bot mentions

**wechat_work_adapter / wechat_work_router** ← new module
- Webhook URL POST with JSON payload
- Parses \`event_type: send_interact\` and text message events

**whatsapp_adapter / whatsapp_router**
- Bridge-based: \`bridge_url\` + \`device_id\` for WhatsApp Web bridge
- Parses messages and status callbacks; supports media attachments

All five routers support \`HandleInboundForHandler\` for streaming dispatch
and accept an optional \`SessionSupervisor\` for multi-turn history.

## Test plan
- [ ] \`gleam test\` — 1640 passed, no failures
- [ ] \`test/adapters/google_chat_adapter_test.gleam\`
- [ ] \`test/adapters/lark_adapter_test.gleam\`
- [ ] \`test/adapters/mattermost_adapter_test.gleam\`
- [ ] \`test/adapters/wechat_work_adapter_test.gleam\`
- [ ] \`test/adapters/whatsapp_adapter_test.gleam\`"

echo "PR 6 created."

# ──────────────────────────────────────────────────────────────
# PR 7 — Common router + channel registry + bootstrap
# ──────────────────────────────────────────────────────────────
gh pr create \
  --base release/06-adapters-others \
  --head release/07-router-bootstrap \
  --title "feat(bootstrap): shared command router, channel registry, and main entry wiring" \
  --body "## What this PR does

Wires all channel adapters into a unified runtime: the shared command router
handles all commands uniformly, the channel registry orchestrates startup and
streaming dispatch, and \`supernova.gleam\` bootstraps the whole system.

**Depends on:** release/06-adapters-others

## Commits

| Hash | Subject |
|------|---------|
| \`6905448\` | feat(router): shared command handling, model picker, and streaming dispatch |
| \`a48cf56\` | feat(bootstrap): main entry wiring, channel registry, and project wizard |

## Details

### channel_common_router.gleam

The single source of truth for command handling across all channels:
- \`/help\`, \`/start\`, \`/status\`, \`/model\` — uniform across Discord, Telegram, Slack, Matrix, and all others
- \`/model\` returns interactive Block Kit / inline keyboard for \`channel_supports_interactions\` channels (Discord, Telegram, Slack); text fallback for the rest
- \`picker_provider:*\` and \`picker_model_select\` callbacks persist full \`ProviderConfig\` in session
- \`handle_inbound_with_session_supervisor()\` enriches LLM config from session before dispatch
- \`InteractiveRouterState\` holds selected config between callbacks within an actor

### channel/registry.gleam

Central orchestrator — \`start_channels_with_handler_and_hooks()\`:
- Registers all enabled channels, each with a \`send_fn\` and optional \`stream_send_fn\`
- \`dispatch_inbound()\`: \`ChannelHandler\` → \`ImmediateReply\` → \`send_fn\`, or \`StreamReply\` → \`stream_send_fn\` consuming \`ChannelStreamEvent\`s
- Discord: gateway bridge + REST client, event injection via \`StartHooks.discord_events\`
- Telegram: long-polling worker, update injection via \`StartHooks.telegram_updates\`
- Slack: inbound hook loop → \`dispatch_inbound\`; \`record_slack_stream_for_test\` in test mode
- Matrix: inbound hook loop → \`dispatch_inbound\`; \`consume_matrix_stream_events\` in test mode
- \`StartHooks\`: deterministic injection for testing without live network connections
- \`OutboundRecord\`: test observer recording all sends/edits/progress events with action and content
- Typing keepalive: re-emits typing at configurable intervals during long streams

### supernova.gleam + wizard.gleam

- \`build_channel_handler()\` creates one \`ChannelHandler\` from all configured routers
- Shared \`SessionSupervisor\` passed into every channel router at startup
- Clean shutdown: \`registry.stop_channels()\` then \`supervisor.stop()\`
- \`wizard.gleam\`: interactive multi-step setup with provider/model selection and credential configuration

## Test plan
- [ ] \`gleam test\` — 1640 passed, no failures
- [ ] \`test/channel/registry_test.gleam\` — full E2E suite for all 9 channels:
  - Start/stop lifecycle
  - Discord, Telegram, Slack, Matrix inbound dispatch
  - Streaming with typing keepalive
  - Model selection persistence end-to-end
- [ ] \`test/adapters/channel_router_test.gleam\`, \`new_channel_router_test.gleam\`, \`unified_router_test.gleam\`
- [ ] \`test/wizard/wizard_test.gleam\`"

echo "PR 7 created."

# ──────────────────────────────────────────────────────────────
# PR 8 — Docs + PRD
# ──────────────────────────────────────────────────────────────
gh pr create \
  --base release/07-router-bootstrap \
  --head release/08-docs-prd \
  --title "chore: update docs, infra, examples, and mark all 29 user stories complete" \
  --body "## What this PR does

Non-code updates: documentation, infrastructure config, quickstart example,
browser automation npm package, and PRD with all 29 user stories marked
\`passes: true\`.

**Depends on:** release/07-router-bootstrap

## Commits

| Hash | Subject |
|------|---------|
| \`f2d3946\` | chore: update docs, infra, examples, and add browser automation deps |
| \`b4381d0\` | chore(prd): mark US-027 through US-029 as complete |

## Changes

- **README.md** — updated channel and LLM provider list
- **TODO.md** — completed feature checklist through US-029
- **docker-compose.yml** — minor infra update
- **examples/quickstart/supernova.yaml** — all providers and channels documented
- **package.json / scripts/browser_runner.mjs** — Playwright dependency for browser tool
- **tasks/ralph-progress.md** — implementation progress log
- **tasks/prd.json** — all 29 user stories \`passes: true\`

## Final validation

\`\`\`
gleam format --check src test  ✓
gleam build                    ✓
gleam test                     1640 passed, no failures ✓
\`\`\`"

echo "PR 8 created."
echo ""
echo "All 8 PRs created. Merge order: PR1 → PR2 → PR3 → PR4 → PR5 → PR6 → PR7 → PR8"
