# Supernova

**Supernova is an AI operating system built on the BEAM.**

Most agent frameworks give you a loop that calls an LLM and runs tools. Supernova gives you the layer underneath: resource accounting, workspace isolation, a central scheduler, a shared world model, and a formal syscall interface between agents and the kernel. It is the infrastructure that makes multi-agent systems safe to run in production.

[![Package Version](https://img.shields.io/hexpm/v/supernova)](https://hex.pm/packages/supernova)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/supernova/)

---

## The problem it solves

When you run more than one agent in production, three things happen eventually:

1. **A runaway loop burns your API budget.** Without per-agent token accounting and hard limits, you discover this on the invoice.
2. **An agent touches files it should not.** Without workspace isolation and a capability manifest, any agent with shell access can be instructed to do anything.
3. **Multi-agent coordination fails silently.** Without a task graph and typed sub-agent results, fire-and-forget is the only option.

Supernova addresses all three before they happen.

---

## What it provides

| Kernel Primitive | Implementation |
|---|---|
| Agent processes | OTP actors, one per session, supervised |
| Resource accounting | `ResourceLedger` — tokens, tool calls, CPU per agent |
| Budget enforcement | `BudgetPolicy` — configurable per agent or class |
| Workspace isolation | `WorkspacePolicy` — path-level allow/deny with sub-agent inheritance |
| Tool capability control | `CapabilityManifest` — per-agent tool allowlist/denylist |
| Audit trail | `AuditLog` — append-only log of every operation |
| Fair scheduling | `KernelScheduler` — round-robin with starvation detection |
| Cooperative preemption | `CheckpointProtocol` — yield/pause/abort on budget exhaustion |
| Task orchestration | `TaskGraph` + `ProjectOrchestrator` — DAG with cycle detection and cascade cancellation |
| Shared knowledge | `WorldModel` — versioned, append-only fact repository |
| Memory federation | `MemoryFederation` — promotes local facts to global world model |
| Syscall interface | `SyscallGateway` — formal agent-to-kernel API |

---

## Quick start

```sh
# 1. Start Postgres
docker compose up -d postgres

# 2. Install dependencies
gleam deps download

# 3. Configure (interactive)
gleam run -m supernova/wizard_main

# 4. Run
gleam run
```

See [GETTING_STARTED.md](GETTING_STARTED.md) for the full walkthrough.

Additional documentation:

- [Architecture Overview](docs/architecture/ARCHITECTURE.md)
- [Components and Responsibilities](docs/architecture/COMPONENTS.md)
- [Contributing Guide](docs/CONTRIBUTING.md)
- [Docker Operations Guide](docs/operations/DOCKER.md)
- [Podman Operations Guide](docs/operations/PODMAN.md)
- [Interaction Guide](docs/operations/INTERACTION.md)

---

## Requirements

- [Gleam](https://gleam.run/) >= 1.0.0
- [Erlang/OTP](https://www.erlang.org/) >= 25.0
- PostgreSQL >= 12

Or just use `docker compose up` which handles all of it.

---

## Architecture

Supernova follows a kernel/userland split. Agents interact with system resources exclusively through `SyscallGateway`. Every syscall passes through authentication → `WorkspacePolicy` → `BudgetPolicy` → execution → `AuditLog`.

```
Agents (userland)
    │
    ▼
SyscallGateway
    │
    ├── WorkspacePolicy   (can this agent access this path?)
    ├── BudgetPolicy      (does this agent have quota remaining?)
    ├── CapabilityManifest (is this tool allowed for this agent?)
    ├── ResourceLedger    (charge the operation)
    └── AuditLog          (record the outcome)
```

The `KernelScheduler` runs above all of this, deciding which agents get CPU time based on priority, remaining budget, and starvation detection.

---

## Configuration

Supernova is configured via `supernova.yaml`. Sensitive values (API keys, tokens) can be set as environment variables instead.

```yaml
app_name: my-assistant
environment: production
log_level: info

providers:
  default:
    provider: anthropic
    model: claude-sonnet-4-5

budgets:
  default:
    tokens_per_hour: 100000
    tool_calls_per_minute: 60
    max_recursion_depth: 25

telegram:
  enabled: true
  # token: set SUPERNOVA_TELEGRAM_TOKEN env var

discord:
  enabled: false
```

See [examples/quickstart/supernova.yaml](examples/quickstart/supernova.yaml) for a complete annotated example.

---

## Development

```sh
gleam run              # Start the server
gleam test             # Run all tests
gleam format           # Format source code
gleam format --check   # Check formatting (CI)
gleam check            # Type check
```

---

## Status

Supernova already provides a complete operating-system-style kernel layer for agent runtimes: resource ledger, scheduler, workspace policy, world model, and syscall interface.

Current channel support:

- Functional routers: Telegram, Discord
- Scaffolded routers (shared contract): Matrix, Lark, Google Chat, Slack, Mattermost, WeChat Work, WhatsApp
