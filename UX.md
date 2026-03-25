# UX/UI Analysis for Supernova Channels (Discord, Telegram and Others)

Date: 2026-03-24

## Scope

This document consolidates a deep comparative analysis of:

- `Pincer/`
- `openclaw/`

with focus on channel UX/UI architecture:

- Port contracts and adapter boundaries
- Interactive commands (buttons/select/callbacks)
- Provider/model selection via UI (not text-first)
- Agent bootstrap directly from channels
- Session routing and safety guarantees
- UX parity across Discord, Telegram, and other channels

## Executive Summary

Supernova has solid progress in routing and executor integration, but UX is still mostly text-only at the Port boundary.

Pincer and OpenClaw show a stronger pattern: interaction primitives are treated as first-class contract elements, then each adapter renders them natively (Discord components, Telegram inline keyboards, etc.).

Main gap to close:

- Supernova `channel/port.gleam` currently supports plain text replies only.
- No normalized callback/interaction event model in Port.
- No native provider/model picker flow by buttons in Discord/Telegram.
- No channel-first bootstrap flow for selecting/starting agent directly in-channel.

## Deep Findings

### 1) Port contract and adapter responsibilities

#### Pincer

Strong behavior contract in `lib/pincer/ports/channel.ex`:

- Transport callbacks (`send_message`, `update_message`, routing helpers)
- Session event callbacks (`on_agent_partial`, `on_agent_response`, `on_agent_error`, `on_approval_ui`, etc.)
- Shared pubsub delivery + per-session workers

Shared interaction policy in `lib/pincer/core/channel_interaction_policy.ex`:

- Canonical action payloads (`select_provider:*`, `select_model:*`, `page:*`, `show_menu`, `appr:y/n`)
- Payload size enforcement per platform:
  - Telegram: 64 bytes
  - Discord: 100 bytes
- Strict parser reused by adapters

#### OpenClaw

Richer pluginized contract model in:

- `src/channels/plugins/types.adapters.ts`
- `src/channels/plugins/types.core.ts`

Highlights:

- Layered adapters (setup/config/outbound/messaging/threading/actions/gateway/security)
- Discovery/execution separation for message actions
- Channel capability metadata and schema contributions

Interactive normalization in `src/interactive/payload.ts`:

- Canonical blocks:
  - `text`
  - `buttons`
  - `select`
- Text fallback resolver for non-interactive surfaces

#### Supernova (current)

`src/supernova/channel/port.gleam` is clean but text-centric:

- Inbound `ChannelMessage` is normalized
- Outbound `ChannelReply` has only:
  - `channel_id`
  - `content`
  - `reply_to_id`

Missing:

- Outbound interactive components in Port
- Inbound interaction callback events in Port
- Shared callback/action policy module

### 2) Provider/model selection UX (button-driven)

#### Pincer

Discord and Telegram implement interactive picker flow:

- `/models` => provider buttons
- provider click => model list (paginated)
- model click => apply model
- back/menu actions

Relevant files:

- `lib/pincer/channels/discord.ex`
- `lib/pincer/channels/telegram.ex`
- `lib/pincer/core/ux/model_keyboard.ex`

#### OpenClaw

More advanced and resilient picker systems:

- Telegram compact callback encoding for 64-byte limit:
  - `extensions/telegram/src/model-buttons.ts`
- Discord rich picker with select menus and action states:
  - `extensions/discord/src/monitor/model-picker.ts`
- Mattermost interactive picker parity:
  - `extensions/mattermost/src/mattermost/model-picker.ts`

Also reuses common provider/model source:

- `src/auto-reply/reply/commands-models.ts`

#### Supernova (current)

- Help text mentions `/model`, but flow is text-only
- No button/select/callback route in channel adapters
- No standardized picker state machine

### 3) Agent bootstrap directly in channel

#### Pincer

Session + agent resolution is channel-aware:

- `lib/pincer/core/session_resolver.ex`

Bootstrap flow triggered from commands:

- `Discord`: `maybe_start_project_execution(...)`
- `Telegram`: `maybe_start_project_execution(...)`

Files:

- `lib/pincer/channels/discord.ex`
- `lib/pincer/channels/telegram.ex`

#### OpenClaw

High-coverage session init/routing pipeline:

- `src/auto-reply/reply/session.ts`
- `src/channels/session.ts`
- `src/gateway/server-methods/chat.ts`
- `src/auto-reply/dispatch.ts`

Includes:

- deterministic `sessionKey` strategy
- `resolveSessionAgentId(...)`
- native command targeting (`CommandTargetSessionKey`)
- robust reset/bootstrap semantics

#### Supernova (current)

- Routers call executor correctly
- Session resolution exists per router
- Missing explicit UX flow for:
  - choose agent in-channel
  - bootstrap/start agent from channel interaction
  - persist and display active agent context in command UI

### 4) Approval and action UX

#### Pincer

Approval action is first-class and interactive:

- `on_approval_ui` renders approval buttons
- callback parser maps to approve/reject

Files:

- `lib/pincer/channels/discord/session.ex`
- `lib/pincer/channels/telegram/session.ex`
- `lib/pincer/core/channel_interaction_policy.ex`

#### OpenClaw

Action lifecycle and discovery are robust:

- discovery at tool schema/capability level
- execution with server-side guardrails

File:

- `src/channels/plugins/message-action-discovery.ts`

#### Supernova (current)

- No interaction event pathway yet
- Approval/button lifecycle not represented in Port

### 5) Channel parity reality check

- Pincer: Discord + Telegram are strong; Slack is more basic
- OpenClaw: very strong multi-channel abstractions and plugin architecture
- Supernova: routers + config + wizard expanded, but channel UX interaction parity still pending

## Proposed Target for Supernova

### A) Upgrade Port to interaction-aware contract

Extend `src/supernova/channel/port.gleam` with:

- outbound interaction primitives (`buttons`, `select`, optional metadata)
- inbound interaction callback message variant (normalized action payload)
- channel capability hints (interactive support vs text fallback)

### B) Create shared interaction policy

New core module (suggested):

- `src/supernova/core/channel_interaction_policy.gleam`

Responsibilities:

- canonical action IDs
- strict parse/validation
- Telegram/Discord payload size constraints

### C) Implement Discord + Telegram picker UX first

Flows:

- `/models` opens provider buttons
- provider => model picker with pagination + back
- model selection applies to session/agent context
- keep text fallback for unsupported surfaces

### D) Add direct channel bootstrap flow

Channel-native flow for:

- selecting/confirming target agent
- starting/resuming session with that agent
- reflecting active context in status/help outputs

### E) Extend parity/fallback for other channels

For Slack/Mattermost/new adapters:

- use interactive features where available
- otherwise show deterministic text fallback with equivalent command path

## Prioritized TODO (Execution)

1. `design-port-interaction-contract`
2. `implement-discord-telegram-interactive-pickers`
3. `implement-channel-agent-bootstrap`
4. `extend-other-channel-fallback-interactions`
5. `add-ui-ux-regression-tests`
6. `validate-suite-after-ux-upgrade`

## Suggested File Touchpoints (Supernova)

- `src/supernova/channel/port.gleam`
- `src/supernova/adapters/channel_common_router.gleam`
- `src/supernova/adapters/discord_router.gleam`
- `src/supernova/adapters/telegram_router.gleam`
- `src/supernova/core/ux.gleam`
- `src/supernova/config.gleam`
- `src/supernova/wizard.gleam`
- `src/supernova.gleam`
- `test/adapters/*`
- `test/config/*`
- `test/wizard/*`

## Reference Files Used in Audit

Pincer:

- `lib/pincer/ports/channel.ex`
- `lib/pincer/core/channel_interaction_policy.ex`
- `lib/pincer/core/ux/model_keyboard.ex`
- `lib/pincer/channels/discord.ex`
- `lib/pincer/channels/telegram.ex`
- `lib/pincer/channels/discord/session.ex`
- `lib/pincer/channels/telegram/session.ex`
- `lib/pincer/core/session_resolver.ex`

OpenClaw:

- `src/interactive/payload.ts`
- `src/auto-reply/reply/commands-models.ts`
- `src/channels/plugins/types.adapters.ts`
- `src/channels/plugins/types.core.ts`
- `src/channels/plugins/message-action-discovery.ts`
- `src/channels/session.ts`
- `src/auto-reply/dispatch.ts`
- `src/auto-reply/reply/session.ts`
- `src/gateway/server-methods/chat.ts`
- `extensions/telegram/src/model-buttons.ts`
- `extensions/discord/src/monitor/model-picker.ts`
- `extensions/mattermost/src/mattermost/model-picker.ts`
