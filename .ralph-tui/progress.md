# Supernova Implementation Progress

## Codebase Patterns

### Bootstrap Pattern
- **Service Startup Order**: Start Session Supervisor first, then MCP Manager, then channel adapters
- **Graceful Shutdown Order**: Stop channels first (no new messages), then sessions (complete conversations), then MCP servers
- **Config Fallback**: Always provide defaults when config file is missing - don't block startup on config errors
- **Actor Lifecycle**: Use OTP actors for all stateful services to enable clean shutdown

### MCP Integration Pattern
- **Real STDIO Communication**: Use Erlang ports for external process communication with line-buffered I/O
- **JSON-RPC 2.0**: Implement proper protocol with request/response correlation via IDs
- **Dynamic to JSON**: When extracting JSON-RPC result fields, use FFI to convert Erlang Dynamic types back to JSON strings
- **Actor-based Transport**: Wrap Erlang ports in OTP actors for safe concurrent access and lifecycle management

### Error Handling
- **Process Death Detection**: Erlang ports send `{exit_status, N}` messages when external process dies
- **Timeout Handling**: Use receive...after pattern in Erlang for robust timeout handling
- **Graceful Degradation**: Return empty tool lists on parse failures rather than failing entirely

---

## [2026-03-23] - US-005
- Implemented real MCP server communication via STDIO using Erlang ports
- Replaced simulation with full JSON-RPC 2.0 protocol implementation
- Files changed:
  - `src/supernova/adapters/mcp_manager.gleam` - Manager with real protocol
  - `src/supernova/adapters/mcp/stdio.gleam` - STDIO transport with Erlang ports
  - `src/supernova_mcp_ffi.erl` - FFI for port operations and JSON encoding
  - `test/mock_mcp_server.py` - Mock server for testing
  - `test/adapters/mcp_stdio_test.gleam` - STDIO transport tests
  - `test/adapters/mcp_manager_test.gleam` - Manager tests with real protocol

**Learnings:**
- **Erlang Port Communication**: Ports provide line-buffered STDIO with `{line, N}` option, perfect for JSON-RPC
- **Port Ownership**: Must use `erlang:port_connect(Port, self())` to transfer port ownership between processes
- **Dynamic to JSON**: Gleam's `decode.dynamic` extracts values but doesn't provide reverse conversion - need FFI
- **Binary vs String**: Erlang terms from JSON parsing use binaries; must quote them in JSON output
- **Test-Driven Success**: Writing mock server first enabled full protocol testing without external dependencies
- **JSON-RPC Error Handling**: Check for `error` field first, then extract `result` - order matters
- **Graceful Degradation**: Return empty arrays on parse failures (e.g., tools list) prevents cascading failures
- **Process Lifecycle**: Clean up ports in Stop message handler and on actor start failure

**Gotchas:**
- The `decode.json` function doesn't exist in newer gleam_stdlib - use `decode.dynamic` instead
- Erlang's `string:join/2` function needs list of strings, not binaries
- When formatting JSON from Erlang terms, binaries must be quoted even when they appear in nested structures
- Port messages must be read by the controlling process or port_connect must be called first
- `{line, N}` buffering means incomplete lines trigger `{noeol, Partial}` - must collect fragments

---
## [2026-03-23] - US-006
- Implemented functional entry point with bootstrap sequence and graceful shutdown
- Created main() function that loads config, starts services, and awaits shutdown
- Added integration tests for bootstrap process
- Files changed:
  - `src/supernova.gleam` - Complete entry point with bootstrap and shutdown
  - `supernova.yaml` - Example configuration file
  - `test/bootstrap_test.gleam` - Integration tests for bootstrap sequence

**Learnings:**
- **Bootstrap Sequence**: Session Supervisor → MCP Manager → Channel Adapters (future)
- **Shutdown Sequence**: Reverse order - Channels → Sessions → MCP servers
- **Config Robustness**: Fall back to defaults if config file missing - don't block startup
- **process.sleep_forever()**: Cleanest way to wait for Ctrl+C shutdown in main()
- **Integration Tests**: Test full bootstrap flow to ensure all services start and stop cleanly
- **Config File Format**: YAML with providers, discord, telegram, and database sections
- **Service Container**: Use a Services type to hold all running service handles for shutdown

**Gotchas:**
- The yay library has a bug where file errors return FFI types that don't match Gleam type definitions
- Workaround: Catch all config errors and fall back to defaults instead of trying to pattern match specific errors
- Must create supernova.yaml for clean startup (or handle missing file gracefully)
- process.sleep_forever() is interrupted by SIGTERM (Ctrl+C) which triggers Erlang shutdown
- Actors need small delay after stop() calls to fully terminate in tests

---
## [2026-03-23] - US-020
- Implemented MemoryFederation: pipeline to promote local memory facts to the global WorldModel
- Files changed:
  - `src/supernova/core/memory_federation/types.gleam` — CandidateFact, FederationResult, FederationConfig, FederationState, ClassificationResult, FederationCommand, initial_state/1, default_config/1
  - `src/supernova/core/memory_federation/pure.gleam` — federate/3: classifies candidates into to_promote / kept_local / rejected by threshold
  - `src/supernova/core/memory_federation/actor.gleam` — OTP actor wrapping pure logic; asserts promoted facts to WorldModel, returns FederationResult with fact_ids
  - `test/core/memory_federation/pure_test.gleam` — 11 pure tests covering all three classification buckets, threshold boundaries, custom thresholds, telemetry
  - `test/core/memory_federation/actor_test.gleam` — 6 integration tests with real WorldModel actor

**Learnings:**
  - **Two-phase result pattern**: When pure logic must classify for side effects that produce IDs (WorldModel fact_ids), split into `ClassificationResult` (pure) + `FederationResult` (actor) — actor executes the side effects and collects IDs
  - **list.filter_map for side-effecting promotion**: Using `list.filter_map` to assert facts and collect only successful fact_ids is clean and handles partial failures gracefully
  - **type vs constructor import**: Gleam requires `type FederationConfig` in imports for type annotations; omitting `type` causes "value in scope but no type" errors
  - **Irrefutable tuple patterns**: `let assert #(a, b, c) = ...` on plain tuples generates "redundant assertion" warnings; use plain `let` instead
  - **Pre-existing test failure**: `agent_queue/actor_test.next_fifo_within_same_priority_test` has a pre-existing failure (ordering bug); not related to this US
---

## [2026-03-23] - US-022
- Implemented formal syscall interface for agent→kernel interactions
- Syscall already existed; fixed float formatting bug in WriteWorld confidence output
- Files changed:
  - `src/supernova/core/syscall/actor.gleam` — Added do_float_to_string FFI call
  - `src/supernova_ledger_ffi.erl` — Added format_float/1 to format floats without trailing zeros
  - `src/supernova/core/syscall/types.gleam` — All syscall operations defined
  - `src/supernova/core/syscall/pure.gleam` — Authentication and dispatch logic
  - `src/supernova/core/syscall/actor.gleam` — Full pipeline: auth → WorkspacePolicy → BudgetPolicy → execute → AuditLog
  - `test/core/syscall/pure_test.gleam` — 22 tests covering happy path + denial for all operations
  - `test/core/syscall/actor_test.gleam` — 22 integration tests covering full pipeline

**Learnings:**
  - **Erlang float formatting**: `float_to_binary/1` produces scientific notation for some values; use `io_lib:format("~f", [F])` with custom trailing-zero stripping for clean decimal output
  - **Syscall architecture**: The syscall gateway is a policy enforcement point - all agent→system interactions should go through it, but the actual tool implementations (file_system, safe_shell) still use direct FFI pending migration
  - **Pre-existing test failure**: `agent_queue/actor_test.next_fifo_within_same_priority_test` - ordering bug unrelated to this US

**Gotchas:**
  - Float 0.9 in binary floating point is not exact, so naive string conversion produces extra digits
  - `~g` format in Erlang still produces trailing zeros in some cases; need custom stripping function
  - Syscall run_op is currently a stub returning mock data - actual operations would require FFI implementations or delegation to existing tool modules
---
