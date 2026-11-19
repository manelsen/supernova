# Repository Guidelines

This document provides essential information for AI assistants working with the Supernova codebase.

## Hard Rules (read first)

These rules apply to every contributor, human or automated (executor agents, CodeRabbit Autofix, reviewers). They come from real incidents in this repository.

### Toolchain

- **Use exactly the versions in `.tool-versions`** (Gleam 1.19.2, Erlang 28.5.0.8). Check `gleam --version` before formatting.
- **Never run `gleam format` over all of `src`/`test` with a different Gleam version.** Another version reformats untouched files and breaks the CI `format --check`. If your local version differs, format only the files you touched and inspect the diff.

### Safety in tests

- **No test may execute a blocked or destructive command.** A test that ran `find . -delete` once deleted the repository. Test shell blocking only through `safe_shell.validate/1`, never by running the command.
- Tests use no real network, real tokens or real LLM. The LLM is the mock provider.
- No fixed `process.sleep` to establish concurrent state; use the test clock (`supernova_mock_ffi:clock_set/1`) or explicit synchronization.
- Only the process that owns a `Subject` receives on it. Jobs and handlers create their own reply subjects.

### Workflow

- **TDD:** write the test, confirm it fails, then implement. Record the failing run in the commit message.
- One commit per story when working from a PRD, with the commit message the PRD gives.
- Pull before committing on a shared branch: executor agents and CodeRabbit Autofix may both commit to the same PR branch.
- **Never merge, tag, publish a release or push images.** The maintainer does that after review.

### Kernel invariants

- **An agent's `self/` directory and its workspace `.supernova/` directory are kernel state.** Only the kernel or runtime writes there; no tool may read or write them. Do not weaken `workspace_policy` checks for these paths.
- **Every LLM call is admitted through the resource ledger** (`admit_llm_call`) and charged to the owning principal. If admission is denied, the operation does not happen.
- **Fail closed:** when access, budget or ledger state is unavailable, deny.
- In closed-group mode the agent's core (`self/core.md`) is never rewritten after birth.

### Maintainer-owned content

- **Do not write or change the content of `priv/constellation/` or `priv/reflection/`.** The constellation and the birth, reflection and drift prompts belong to the maintainer. Executors may create test fixtures and clearly marked provisional files only when a PRD asks for them.
- Do not touch `blackboard` or `memory_federation` unless a PRD says so.

## Project Overview

**Supernova** is an AI operating system built on the BEAM (Erlang VM) using the Gleam language. It provides infrastructure for multi-agent systems with:

- Resource accounting (tokens, tool calls, CPU per agent)
- Workspace isolation (path-level allow/deny policies)
- Central scheduler with fair scheduling and starvation detection
- Shared world model for versioned facts
- Formal syscall interface between agents and kernel
- Budget enforcement with configurable limits
- Audit trail for all operations

## Architecture & Data Flow

### Kernel/Userland Split

Supernova follows a strict kernel/userland architecture. Agents (userland) interact with system resources exclusively through `SyscallGateway`:

```
Agents (userland)
    │
    ▼
SyscallGateway
    │
    ├── WorkspacePolicy      (can this agent access this path?)
    ├── BudgetPolicy         (does this agent have quota remaining?)
    ├── CapabilityManifest   (is this tool allowed for this agent?)
    ├── ResourceLedger       (charge the operation)
    └── AuditLog             (record the outcome)
```

The `KernelScheduler` runs above all of this, deciding which agents get CPU time.

### Three-Layer Component Pattern

Each core component follows a three-layer architecture:

1. **types.gleam** - Public type definitions (enums, records)
2. **pure.gleam** - Business logic (pure functions, no side effects)
3. **actor.gleam** - State management with FFI side effects (OTP actors)

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `src/supernova/` | Main application source |
| `src/supernova/adapters/` | Channel integrations (Telegram, Discord, etc.) |
| `src/supernova/core/` | Kernel primitives (scheduler, budget, workspace, audit) |
| `src/supernova/llm/` | LLM provider clients and dispatch |
| `src/supernova/channel/` | Port contract definitions |
| `src/supernova/tools/` | Tool implementations (shell, filesystem) |
| `test/` | Test suite mirroring source structure |

### Data Flow

1. `supernova.main()` loads config and starts supervisor services
2. Inbound channel payloads normalized via `channel/port` types
3. Routers resolve session scope and route to executor
4. Runtime executes LLM/tool loop under scheduler + budget + capability policies
5. Outbound replies return to channel adapters for delivery
6. Resource usage logged through audit and telemetry

## Development Commands

```sh
# Install dependencies
gleam deps download

# Build the project
gleam build

# Run the application
gleam run

# Run the interactive setup wizard
gleam run -m supernova/wizard_main

# Run tests
gleam test

# Format code (Gleam 1.19.2 only, see Hard Rules)
gleam format src test

# Check formatting (CI gate)
gleam format --check src test

# Type check without building
gleam check
```

### Docker Development

```sh
# CLI (recommended for local development)
bin/supernova help            # show available commands
bin/supernova configure       # interactive setup wizard
bin/supernova start           # build + start container
bin/supernova logs            # tail container logs
bin/supernova stop            # stop services
bin/supernova restart         # restart
bin/supernova test           # run tests

# Or use Makefile directly
make up-build   # build + start (first time or after code changes)
make up         # start without rebuilding
make logs       # tail container logs
make down       # stop services
make clean      # stop + remove volumes
make configure  # run setup wizard
```

## Code Conventions

### Naming Conventions

- **Modules**: `snake_case.gleam`
- **Functions/Variables**: `snake_case`
- **Types/Records**: `PascalCase`
- **Constants**: `SCREAMING_SNAKE_CASE`

### Import Organization

Imports follow a standard order:
1. Standard library (`gleam/...`)
2. Third-party packages
3. Internal project imports

### Error Handling

All fallible operations return `Result` types. Use pattern matching on Results:

```gleam
case some_operation() {
  Ok(value) -> handle_success(value)
  Error(reason) -> handle_failure(reason)
}
```

### Documentation Style

Public functions use triple-slash doc comments:

```gleam
/// Does something useful.
///
/// ## Arguments
/// - `input`: The input value to process
/// - `config`: Optional configuration
pub fn process(input: String, config: Config) -> Result(Output, ProcessError) {
  // ...
}
```

### Pure/Actor Separation

- **pure.gleam** files contain business logic (no side effects)
- **actor.gleam** files handle orchestration and state management
- Keep adapter logic at Port boundaries; avoid leaking channel-specific payloads into core

### Module Pattern (Adapters)

Adapters implement a consistent pattern:

```gleam
// src/supernova/adapters/telegram_router.gleam
// src/supernova/adapters/discord_router.gleam
// etc.
```

Each adapter:
1. Translates channel-specific payloads into `channel/port` types
2. Uses shared `channel_common_router` for validation and routing
3. Handles outbound rendering back to channel format

## Important Files

### Entry Points

| File | Purpose |
|------|---------|
| `src/supernova.gleam` | Main application bootstrap |
| `src/supernova/wizard_main.gleam` | Interactive setup wizard |
| `src/supernova/config.gleam` | Configuration loading and validation |

### Configuration

| File | Purpose |
|------|---------|
| `supernova.yaml` | Runtime configuration (providers, budgets, channels) |
| `gleam.toml` | Project dependencies and build target |

### Key Core Modules

| File | Purpose |
|------|---------|
| `src/supernova/core/agent.gleam` | Generic agent actor implementation |
| `src/supernova/core/syscall/types.gleam` | Formal syscall interface definitions |
| `src/supernova/core/kernel_scheduler/actor.gleam` | Fair agent scheduling |
| `src/supernova/core/resource_ledger/actor.gleam` | Per-agent resource accounting |
| `src/supernova/core/budget_policy/actor.gleam` | Budget enforcement |
| `src/supernova/core/workspace_policy/actor.gleam` | Filesystem isolation |
| `src/supernova/core/world_model/actor.gleam` | Shared versioned facts |
| `src/supernova/core/session/supervisor.gleam` | Session lifecycle management |

### Port Contract

| File | Purpose |
|------|---------|
| `src/supernova/channel/port.gleam` | Normalized channel message types |

## Runtime & Tooling

| Requirement | Version |
|-------------|---------|
| Gleam | 1.19.2 (`.tool-versions`) |
| Erlang/OTP | 28.5.0.8 (`.tool-versions`) |
| PostgreSQL | >= 12 |

### Key Dependencies

- `gleam_otp` - Actor/supervisor patterns
- `gleam_json` - JSON serialization
- `pog` - PostgreSQL driver
- `stratus` - WebSocket support
- `yay` - YAML parsing
- `envoy` - Environment variables

### Build Target

- **Platform**: Erlang/OTP (BEAM)
- **Package Manager**: Gleam native (gleam.toml)
- **Docker Base**: erlang:28.5.0.8-alpine

## Testing & QA

### Test Framework

Gleam uses **Gleeunit** for testing (built into the standard library).

### Test Organization

- Tests live in `test/` directory mirroring `src/` structure
- Test files named `*_test.gleam`
- Fixtures in `test/fixtures/` for JSON API responses

### Test Examples

```gleam
// Pure function test
import gleeunit/should
import supernova/core/checkpoint/pure

@test
fn pure_function_test() {
  pure.transform(input)
  |> should.equal(expected)
}

// Actor test (with full lifecycle)
@test
fn actor_integration_test() {
  // Start actor, send messages, verify behavior, stop
}
```

### Quality Gates

Before opening a PR, ensure:

```sh
gleam --version                     # Must be 1.19.2
gleam format --check src test       # Must pass
gleam build --warnings-as-errors    # No warnings
gleam test                          # All tests green
make coverage                       # Line coverage gate (75%)
```

CI enforces:
- Format checking with Gleam 1.19.2
- Build with warnings as errors
- Full test suite execution and the coverage gate

## Adding New Channels

To add a new channel adapter (e.g., Matrix, Slack):

1. **Implement adapter module** (`src/supernova/adapters/matrix_adapter.gleam`)
2. **Normalize to port types** using `channel/port` contract
3. **Add configuration parsing** in config modules
4. **Add tests** following the adapter test pattern
5. **Add to router** if using shared routing logic

The adapter should:
- Translate inbound messages to `PortInboundMessage`
- Translate outbound replies to channel-specific format
- Handle channel-specific auth and payload structures

## Adding New LLM Providers

LLM providers live in `src/supernova/llm/providers/`:

1. Create provider module implementing the provider contract
2. Add dispatcher case in `src/supernova/llm/client.gleam`
3. Add configuration options in `src/supernova/config.gleam`
4. Add tests for request/response mapping

## Common Patterns

### Syscall Execution

All agent→kernel operations go through SyscallGateway:

```gleam
// In syscall/types.gleam - define syscall types
pub type Syscall {
  SpawnAgent(config: AgentConfig)
  ReadFile(path: String)
  WriteFile(path: String, content: String)
  // ... etc
}

// In syscall handler - enforce policies in order
fn handle_syscall(syscall: Syscall, agent_id: AgentId) {
  // 1. Check WorkspacePolicy
  // 2. Check BudgetPolicy  
  // 3. Check CapabilityManifest
  // 4. Execute and charge ResourceLedger
  // 5. Log to AuditLog
}
```

### Message Passing (Actors)

Actors communicate via message passing:

```gleam
// Send message
process_actor <-- SomeMessage(payload)

// Handle message
pub fn handle_unsafe(state: State, message: Message) -> actor.Next(a, b) {
  case message {
    SomeMessage(payload) -> #(
      updated_state,
      [reply_to <-- Response()],
      actor.continue(updated_state)
    )
  }
}
```
