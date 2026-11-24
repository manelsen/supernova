# Components and Responsibilities

## Bootstrap and Lifecycle

- `src/supernova.gleam`
  - starts core runtime services,
  - reports enabled channels,
  - coordinates shutdown sequence.

## Configuration Layer

- `src/supernova/config.gleam`
  - parses `supernova.yaml`,
  - validates required/optional fields,
  - resolves environment overrides.

## Channel Layer

- `src/supernova/channel/port.gleam`
  - canonical channel contract used by adapters and routers.
- `src/supernova/channel/traits.gleam`, `channel/traits/*`, `channel/catalog.gleam`
  - what the core knows about each channel, declared by the channel.
- `src/supernova/channel/registry.gleam`
  - starts, stops and routes adapters; the starter table lists them.
- `src/supernova/channel/channel_kit.gleam`
  - start hooks, turn dispatch and generic streaming shared by channel runtimes.
- `src/supernova/adapters/*_channel.gleam`
  - per-channel runtime (Telegram, Discord, Slack, Matrix). Only Telegram and
    the harness channel (`sim`) receive messages today; the others send only.
- `src/supernova/adapters/*_router.gleam`
  - per-channel entrypoint routing inbound to common logic.
- `src/supernova/adapters/channel_common_router.gleam`
  - shared command/runtime path across channels.

## Kernel Layer

- `core/kernel_scheduler`: run-queue and fairness logic.
- `core/resource_ledger`: accounting and charge recording.
- `core/budget_policy`: guardrails and policy exceptions.
- `core/workspace_policy`: filesystem access policy.
- `core/capability_manifest`: action authorization policy.
- `core/syscall`: formalized calls from agents to kernel.

## Intelligence and Execution

- `src/supernova/llm/provider.gleam`
  - provider-neutral request/response types.
- `src/supernova/llm/providers/*`
  - provider-specific transport/protocol mapping.
- `src/supernova/llm/client.gleam`
  - provider routing and call orchestration.

## Persistence and Shared Context

- `core/world_model`
  - global facts/knowledge storage.
- `core/memory`
  - session/local memory construction and retrieval.

## Support Services

- `adapters/mcp_manager`
  - MCP integration and tool-server lifecycle.
- `plugins.gleam`
  - plugin registry and plugin execution path.


## Closed Group

- `core/closed_group/*`: the gate every inbound message passes (access, commands, admission, lanes).
- `core/access/*`: admins, members and allowed chats (`/acesso`).
- `core/instance_budget/*`, `core/rate_limit/*`: the instance ceiling and per-person limits.
- `core/agent_queue/*`: one serial lane per chat.
- `core/audit_log/*`: decisions shown by `/auditoria`.

## The Agent's Self

- `self/*`: birth, core, journal, reflection, drift, forgetting and incidents, stored per agent under `/data/agents/<principal>/self/`.
- `priv/constellation/`, `priv/reflection/`: maintainer-owned content used by `self/*`.

## Agenda and Tools

- `agenda/*`: per-person scheduled requests and the 30-second sweeper.
- `tools/*`: built-in tools (`file_system`, `safe_shell`, `web`, `browser`, `github`, `git_inspect`, `canvas`, `process`, `agenda`, `buscar_conversa`, `lembrar`, `computador`).
- `memory/*`: the gate, `lembrar` and their index, client, cost and metrics ([PRD-M](../prd/PRD-M-memoria.md)); off unless `conversation.recall.enabled`.
- `computador/`: the agent's computer, a separate container on gVisor.

## Health and Instrumentation

- `health/*`: `/health`, `/health/live`, `/health/ready`, `/metrics` on port 8080.
- `metrics/*`, `tracing/*`: instrumentation actors. Their current state is in `docs/operations/OBSERVABILITY.md`.

## Harness

- `sim/*`, `harness/*`: the simulated channel, invariant checks and the personas-and-judge harness (`docs/HARNESS.md`).
