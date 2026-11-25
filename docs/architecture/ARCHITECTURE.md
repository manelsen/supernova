# Supernova Architecture

## Overview

Supernova is an AI operating system on the BEAM, organized around a kernel/userland split.

- **Userland**: channel adapters, session-facing flows, UX routing.
- **Kernel**: scheduling, budgets, capability controls, workspace policies, syscall boundary, auditing.

Agents interact with kernel resources through `SyscallGateway`, which centralizes guardrails and accounting.

## High-Level Components

- `supernova.gleam`: process bootstrap and service lifecycle.
- `core/session/*`: session supervision and runtime session model.
- `core/kernel_scheduler/*`: cooperative/fair agent scheduling.
- `core/resource_ledger/*`: per-agent resource accounting.
- `core/budget_policy/*`: quota enforcement and violation handling.
- `core/workspace_policy/*`: filesystem and workspace access controls.
- `core/capability_manifest/*`: tool/capability grants and denials.
- `core/syscall/*`: syscall protocol and execution boundary.
- `core/world_model/*`: persistent shared facts and context memory.
- `core/closed_group/*`, `core/access/*`, `core/instance_budget/*`, `core/agent_queue/*`: the closed-group gate (see below).
- `self/*`: each agent's private self (see below).
- `agenda/*`: scheduled requests.
- `tools/*`: built-in tools, including `computador`.
- `health/*`, `metrics/*`, `tracing/*`: health endpoints and instrumentation (see `docs/operations/OBSERVABILITY.md`).
- `adapters/*`: channel integrations and external system bridges.
- `llm/*`: provider contracts, adapters, and model/catalog support.

## Runtime Flow

1. `supernova.main()` loads config and starts supervisor services.
2. Inbound channel payloads are normalized into `channel/port` types.
3. Routers resolve session scope and route requests into runtime execution.
4. Runtime executes LLM/tool loop under scheduler + budget + capability policies.
5. Outbound reply payloads return to channel adapters for rendering and delivery.
6. Resource usage and events are logged through audit and telemetry components.

## Closed Group

Since v0.4.0 an instance runs as a closed group: it denies everyone who is not on its access list. `core/closed_group/runtime.gleam` is the gate every inbound message goes through:

1. **`/eu`** is answered first, before any check, so an unauthorized person can learn their principal id.
2. **Access** (`core/access`): is this principal an admin or a member, and is this chat allowed?
3. **Commands** answered by the gate without the LLM: `/uso`, `/acesso`, `/teto`, `/auditoria`. `/esquecer` and `/agenda` also skip the checks below, so a person can always ask to forget or remove an agenda entry, even when the ceiling is reached.
4. **Rate limit** (`core/rate_limit`) and **admission** against the person's daily budget and the instance ceiling (`core/instance_budget`). An LLM call reserves tokens in the ledger before it runs and settles the real cost after.
5. **Lanes** (`core/agent_queue`): one serial queue per chat, with limits on pending turns and on the number of lanes. From here the router handles the rest.
6. **Capabilities** per role (`capabilities` in `supernova.yaml`). Members are denied the riskier tools by default.

Every charge goes to `core/resource_ledger` (`/data/ledger/<date>.jsonl`). Every decision goes to `core/audit_log`.

## The Agent's Self

Each person gets their own agent, with a private self under `/data/agents/<principal>/self/` (`src/supernova/self/`):

| Module | Role |
|---|---|
| `constellation`, `sampler`, `birth` | Sample a coherent set of traits from `priv/constellation/constellation.json`, write the core prose, then let the person name the agent. |
| `core` | The core (`core.md`, `core.json`), traits and biography. The core is part of every prompt the agent receives, followed by `priv/constellation/agent_guidance.md`. |
| `journal` | Append-only journal of turns not yet reflected. |
| `reflection` | Turns the journal into experiences and pressures, after a number of turns or hours (`priv/reflection/reflection_prompt.md`). An hourly sweeper checks every agent. |
| `drift` | Pressures that accumulate and decay. Past a threshold, they add a short addendum to the core (`drift_prompt.md`). |
| `forget`, `epoch` | `/esquecer`: erases what the person told the agent and keeps who the agent became. |
| `incidents` | What went wrong in the agent's own turns, in exact terms, so the agent can explain it. |

The maintainer owns `priv/constellation/` and `priv/reflection/`. They are not changed without approval (see `AGENTS.md`).

## Agenda

`src/supernova/agenda/` keeps per-person scheduled requests (cron or one-shot), at most 5 per person. A sweeper runs every 30 seconds and injects due entries into the person's lane as an `[Agenda]` message. The answer is delivered to the person.

## Memory

The person's conversations are kept whole on disk; the model sees the last `conversation.history_limit` messages. To reach the rest there are two tools and a gate (`src/supernova/memory/`, [PRD-M](../prd/PRD-M-memoria.md)):

- `buscar_conversa` (`tools/buscar_conversa.gleam`): every word, without case or accents; exact things (names, numbers, codes).
- `lembrar` (`tools/lembrar.gleam`, `memory/recall.gleam`): a short list of excerpts (nearest by vector, plus most shared words) goes to a decision model (Perplexity's Decider by default, Gemini Decision by configuration), which answers how likely it is that the subject was talked about, and which excerpts. The answer opens with a tone set by that probability ("acho que não", "não lembro bem", confident) and shows the excerpts word for word. The vectors live in `conversations/recall.idx`, which `/esquecer` removes with the conversations.
- The gate (`memory/gate.gleam`): before the first LLM call of a turn, the decision model reads only the message and says whether it asks about the past; if so, the turn starts with `lembrar` already called. Its timeout (2 s) bounds what it can add to a turn; any failure leaves the turn as it would be without memory.

All of it is off unless `conversation.recall.enabled` is set, with the provider's key (`SUPERNOVA_PERPLEXITY_API_KEY` or `SUPERNOVA_GEMINI_API_KEY`). Every call is admitted through the ledger before it is made and settled after, as usage of the provider; past the instance's daily cap, or without a ledger, the memory stands aside. `/metrics` counts gate verdicts, recall bands, corrections and safety refusals, never text (`memory/metrics.gleam`).

## The Agent's Computer

The `computador` tool (`tools/computador.gleam`) talks over HTTP to a separate container (`computador/`), which runs on gVisor and holds no secrets. It has a full shell, files in a volume and a persistent Chromium. Screenshots travel back as images in the conversation (`llm/tool_images.gleam`). The threat model and setup are in [`docs/operations/COMPUTADOR.md`](../operations/COMPUTADOR.md).

## Simulation and Harness

The `sim` channel lets the harness (`src/supernova/harness/`) talk to agents the way a person would. Personas, scenarios and rubrics live in `priv/harness/`. A judge from another model family scores what code cannot check. See [`docs/HARNESS.md`](../HARNESS.md).

## Port and Adapter Boundary

`src/supernova/channel/port.gleam` defines normalized channel contracts:

- inbound messages and interactions,
- outbound replies (text + interaction-capable payloads),
- shared error/result model.

Adapters translate native provider/channel formats into this contract, allowing shared routing logic in common routers.

### Channel traits

The core never matches on channel names. What it needs to know about a channel is declared by the channel in `channel/traits/<name>.gleam` and read through `channel/catalog`:

- whether people on it can be closed-group principals,
- how to tell a private chat, and the key that authorizes a group,
- whether the agenda can reach a person privately,
- its `/help` and `/commands` text, its streaming edit limit and whether it shows typing.

A channel without its own traits module gets `traits.generic`.

### Channel runtimes

`channel/registry.gleam` only starts, stops and routes: a table of starters is the one place that lists the adapters. The runtime of each channel lives with it: `adapters/telegram_channel.gleam` (polling worker, update conversion, leaving unauthorized groups, sending, streaming), `adapters/discord_channel.gleam` (events and interactions, components; receiving is not implemented yet, because the gateway connection in `adapters/discord_gateway.gleam` is a stub), `adapters/slack_channel.gleam` and `adapters/matrix_channel.gleam`. What they share (start hooks, turn dispatch, generic streaming) is in `channel/channel_kit.gleam`, which knows no channel by name.

The core never chooses by channel name: it asks the channel's traits (`channel/traits`, `channel/catalog`), and an architecture test fails if `supernova.gleam` or the common router compares a name. One router serves every channel (`adapters/channel_router.gleam`); the per-channel router modules are thin wrappers. Channels that receive by webhook (WhatsApp, through GOWA) register a route on one shared server, `channel/webhook_server.gleam` (`POST /webhook/<channel>`, verified by the channel, 401 without a valid signature). A message is in the durable inbox before the webhook answers 200. Media a person sends goes through `channel/inbound_media.gleam`: a temporary file, an `[imagem:<id>]` tag in the text, and one read when the turn's messages are built.

**One person, every channel.** A person's first identity (`telegram:123`) is canonical. Identities linked later with `/vincular` (`whatsapp:5511…`, a WhatsApp LID) are aliases of it, in `core/identity/aliases.gleam` (`data_dir/identity/aliases.json`). Aliases are resolved where a principal is derived: in the closed-group gate, before the access check, and in `agent_identity`. So the agent folder, conversations, memory, access, budget and `/esquecer` all follow the person.

## Safety and Control Planes

### Budget Control

`BudgetPolicy` enforces token/tool/recursion constraints and can emit policy events for violation handling.

### Workspace Isolation

`WorkspacePolicy` limits file operations to authorized paths and inheritance rules.

### Capability Governance

`CapabilityManifest` controls which tools/actions are allowed by agent identity.

### Auditability

`AuditLog` records access, refusals, ceilings, births and forgetting (`/auditoria`). The resource ledger records every LLM charge. The state of metrics and tracing is in [`docs/operations/OBSERVABILITY.md`](../operations/OBSERVABILITY.md).

## Extensibility

A new channel/provider integration should:

1. Implement adapter-side normalization into `channel/port` types.
2. Declare its traits in `channel/traits/<name>.gleam` and add them to `channel/catalog`, unless `traits.generic` fits.
3. Put its runtime in `adapters/<name>_channel.gleam`, reusing `channel/channel_kit`, and add a starter to `channel/registry`.
4. Reuse shared channel routing where possible.
5. Add explicit configuration parsing/validation in config modules.
6. Add contract and integration tests for inbound/outbound parity.

## Testing Strategy

- Unit tests for pure policy and transformation modules.
- Actor tests for lifecycle and message routing.
- Contract tests for channel Port↔Adapter mapping.
- Integration tests for command/model-picker/tool-loop behavior.

