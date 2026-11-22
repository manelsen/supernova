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

1. **Access** (`core/access`): is this principal an admin or a member, and is this chat allowed?
2. **Commands** answered without the LLM: `/eu`, `/uso`, `/acesso`, `/teto`, `/auditoria`, `/agenda`, `/esquecer`.
3. **Rate limit** (`core/rate_limit`) and **admission** against the person's daily budget and the instance ceiling (`core/instance_budget`). An LLM call reserves tokens in the ledger before it runs and settles the real cost after.
4. **Lanes** (`core/agent_queue`): one serial queue per chat, with limits on pending turns and on the number of lanes.
5. **Capabilities** per role (`capabilities` in `supernova.yaml`). Members are denied the riskier tools by default.

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
2. Reuse shared channel routing where possible.
3. Add explicit configuration parsing/validation in config modules.
4. Add contract and integration tests for inbound/outbound parity.

## Testing Strategy

- Unit tests for pure policy and transformation modules.
- Actor tests for lifecycle and message routing.
- Contract tests for channel Port↔Adapter mapping.
- Integration tests for command/model-picker/tool-loop behavior.

