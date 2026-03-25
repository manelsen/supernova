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
- `adapters/*`: channel integrations and external system bridges.
- `llm/*`: provider contracts, adapters, and model/catalog support.

## Runtime Flow

1. `supernova.main()` loads config and starts supervisor services.
2. Inbound channel payloads are normalized into `channel/port` types.
3. Routers resolve session scope and route requests into runtime execution.
4. Runtime executes LLM/tool loop under scheduler + budget + capability policies.
5. Outbound reply payloads return to channel adapters for rendering and delivery.
6. Resource usage and events are logged through audit and telemetry components.

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

`AuditLog` and telemetry modules produce event streams that can be consumed for observability and compliance.

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

