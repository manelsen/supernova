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

