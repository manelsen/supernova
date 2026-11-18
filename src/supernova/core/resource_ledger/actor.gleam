//// Resource Ledger — Actor
////
//// Singleton actor that maintains resource consumption counters per agent,
//// plus a per-principal usage trail that can be persisted as JSON Lines.
//// Delegates pure logic to the pure module, executes side effects via FFI.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(ledger) = actor.start()
//// let assert Ok(_) = actor.charge_llm(ledger, "agent_1", 100, 50)
//// let assert Ok(counters) = actor.get_snapshot(ledger, "agent_1")
//// actor.stop(ledger)
//// ```
////
//// With persistence (one `<dir>/YYYY-MM-DD.jsonl` file per UTC day):
////
//// ```gleam
//// let assert Ok(ledger) = actor.start_persistent("/var/lib/supernova/usage")
//// actor.record_llm_usage(ledger, "user_1", "openai", "gpt-4o", 100, 50, 0.01)
//// actor.stop(ledger)
//// ```

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import supernova/core/resource_ledger/pure
import supernova/core/resource_ledger/types.{
  type LedgerCommand, type LedgerError, type LedgerState, type ResourceCounters,
  type ResourceType, type UsageEvent, EmitTelemetry, LLMUsage, LedgerState,
  ToolUsage, WriteAudit,
}
import supernova/core/safe_call

// ============================================================================
// FFI — Timestamp, Audit, File System (Erlang)
// ============================================================================

/// Get current timestamp in milliseconds (Erlang FFI).
@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

/// Write audit log entry (Erlang FFI).
@external(erlang, "supernova_ledger_ffi", "write_audit")
fn ffi_write_audit(
  agent_id: String,
  resource: String,
  amount: Int,
  timestamp: Int,
) -> Result(Nil, String)

/// Emit telemetry event (Erlang FFI).
@external(erlang, "supernova_telemetry_ffi", "write_event")
fn ffi_write_event(
  name: String,
  timestamp: Int,
  agent_id: String,
) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "append_file")
fn ffi_append_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "list_dir")
fn ffi_list_dir(path: String) -> Result(List(String), String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ffi_ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn ffi_delete_file(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn ffi_file_exists(path: String) -> Result(Bool, String)

// ============================================================================
// Types
// ============================================================================

/// Messages that the ledger actor handles.
pub type LedgerMessage {
  /// Charge LLM tokens (prompt + completion)
  ChargeLLM(
    reply_to: Subject(Result(Nil, LedgerError)),
    agent_id: String,
    prompt_tokens: Int,
    completion_tokens: Int,
  )
  /// Charge a tool call
  ChargeTool(
    reply_to: Subject(Result(Nil, LedgerError)),
    agent_id: String,
    tool_name: String,
  )
  /// Charge storage operation
  ChargeStorage(
    reply_to: Subject(Result(Nil, LedgerError)),
    agent_id: String,
    reads: Int,
    writes: Int,
  )
  /// Charge CPU time
  ChargeCPU(
    reply_to: Subject(Result(Nil, LedgerError)),
    agent_id: String,
    cpu_time_ms: Int,
  )
  /// Get resource counters snapshot for an agent
  GetSnapshot(
    reply_to: Subject(Result(ResourceCounters, LedgerError)),
    agent_id: String,
  )
  /// Check if quota exceeded
  CheckQuota(
    reply_to: Subject(Result(Nil, LedgerError)),
    agent_id: String,
    resource: ResourceType,
    limit: Int,
  )
  /// Reset counters for an agent
  ResetCounters(reply_to: Subject(Result(Nil, LedgerError)), agent_id: String)
  /// Get total tokens for an agent
  GetTotalTokens(reply_to: Subject(Int), agent_id: String)
  /// Get total tool calls for an agent
  GetTotalToolCalls(reply_to: Subject(Int), agent_id: String)
  /// Record a completed LLM call in the usage trail
  RecordLLMUsage(
    reply_to: Subject(Nil),
    principal_id: String,
    provider: String,
    model: String,
    prompt_tokens: Int,
    completion_tokens: Int,
    cost_usd: Float,
  )
  /// Record a tool invocation in the usage trail
  RecordToolUsage(
    reply_to: Subject(Nil),
    principal_id: String,
    tool_name: String,
    ok: Bool,
  )
  /// Get the usage trail for one principal
  GetUsage(reply_to: Subject(List(UsageEvent)), principal_id: String)
  /// Get the full usage trail
  GetAllUsage(reply_to: Subject(List(UsageEvent)))
  /// Sum the LLM cost of events whose timestamp satisfies `keep`. Computed
  /// inside the actor so callers never copy the whole usage trail.
  GetLLMCostWhere(reply_to: Subject(Float), keep: fn(Int) -> Bool)
  /// Get the total LLM cost for a UTC day
  GetDailyCost(reply_to: Subject(Float), day: String)
  /// Get the LLM cost for a UTC day for one principal
  GetDailyCostFor(reply_to: Subject(Float), day: String, principal_id: String)
  /// Delete usage trail files older than the retention window
  RotateOldFiles(reply_to: Subject(Nil), now: Int)
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running ledger actor.
pub type ResourceLedger =
  Subject(LedgerMessage)

/// Internal actor state: aggregate counters plus the usage trail.
type ActorState {
  ActorState(
    counters: Dict(String, ResourceCounters),
    events: List(UsageEvent),
    directory: Option(String),
    now: fn() -> Int,
  )
}

// ============================================================================
// Actor Handler
// ============================================================================

/// Execute a list of commands returned by pure functions.
fn execute_commands(commands: List(LedgerCommand)) -> Nil {
  list.each(commands, fn(cmd) {
    case cmd {
      WriteAudit(agent_id, resource, amount, timestamp) -> {
        let _ = ffi_write_audit(agent_id, resource, amount, timestamp)
        Nil
      }
      EmitTelemetry(name, measurements) -> {
        let agent_id = measurement_value(measurements, "agent_id")
        let _ = ffi_write_event(name, ffi_current_timestamp(), agent_id)
        Nil
      }
    }
  })
}

fn measurement_value(
  measurements: List(#(String, String)),
  key: String,
) -> String {
  case
    list.find(measurements, fn(entry) {
      let #(entry_key, _) = entry
      entry_key == key
    })
  {
    Ok(entry) -> {
      let #(_, value) = entry
      value
    }
    Error(_) -> "unknown"
  }
}

/// View the aggregate counters as the pure module's state type.
fn ledger_view(state: ActorState) -> LedgerState {
  LedgerState(counters: state.counters)
}

/// Replace the aggregate counters, keeping the usage trail and config.
fn with_counters(state: ActorState, ledger: LedgerState) -> ActorState {
  ActorState(..state, counters: ledger.counters)
}

/// Append an event to the persisted trail, if persistence is enabled.
fn persist_event(state: ActorState, event: UsageEvent) -> Nil {
  case state.directory {
    Some(directory) -> {
      let path = directory <> "/" <> pure.event_file_name(event)
      let _ = ffi_append_file(path, pure.event_to_json(event) <> "\n")
      Nil
    }
    None -> Nil
  }
}

/// Handle incoming messages and update state.
fn handle_message(
  state: ActorState,
  message: LedgerMessage,
) -> actor.Next(ActorState, LedgerMessage) {
  case message {
    ChargeLLM(reply_to, agent_id, prompt_tokens, completion_tokens) -> {
      let timestamp = state.now()

      // Charge prompt tokens
      let #(ledger1, commands1) =
        pure.charge(
          ledger_view(state),
          agent_id,
          types.LLMTokensPrompt,
          prompt_tokens,
          timestamp,
        )
      execute_commands(commands1)

      // Charge completion tokens
      let #(ledger2, commands2) =
        pure.charge(
          ledger1,
          agent_id,
          types.LLMTokensCompletion,
          completion_tokens,
          timestamp,
        )
      execute_commands(commands2)

      actor.send(reply_to, Ok(Nil))
      actor.continue(with_counters(state, ledger2))
    }

    ChargeTool(reply_to, agent_id, tool_name) -> {
      let timestamp = state.now()
      let #(ledger, commands) =
        pure.charge(
          ledger_view(state),
          agent_id,
          types.ToolCall(tool_name),
          1,
          timestamp,
        )
      execute_commands(commands)

      actor.send(reply_to, Ok(Nil))
      actor.continue(with_counters(state, ledger))
    }

    ChargeStorage(reply_to, agent_id, reads, writes) -> {
      let timestamp = state.now()

      // Charge reads
      let #(ledger1, commands1) =
        pure.charge(
          ledger_view(state),
          agent_id,
          types.StorageRead,
          reads,
          timestamp,
        )
      execute_commands(commands1)

      // Charge writes
      let #(ledger2, commands2) =
        pure.charge(ledger1, agent_id, types.StorageWrite, writes, timestamp)
      execute_commands(commands2)

      actor.send(reply_to, Ok(Nil))
      actor.continue(with_counters(state, ledger2))
    }

    ChargeCPU(reply_to, agent_id, cpu_time_ms) -> {
      let timestamp = state.now()
      let #(ledger, commands) =
        pure.charge(
          ledger_view(state),
          agent_id,
          types.CPUTimeMs,
          cpu_time_ms,
          timestamp,
        )
      execute_commands(commands)

      actor.send(reply_to, Ok(Nil))
      actor.continue(with_counters(state, ledger))
    }

    GetSnapshot(reply_to, agent_id) -> {
      let result = pure.snapshot(ledger_view(state), agent_id)
      actor.send(reply_to, result)
      actor.continue(state)
    }

    CheckQuota(reply_to, agent_id, resource, limit) -> {
      let result =
        pure.quota_exceeded(ledger_view(state), agent_id, resource, limit)
      actor.send(reply_to, result)
      actor.continue(state)
    }

    ResetCounters(reply_to, agent_id) -> {
      let timestamp = state.now()
      let #(ledger, commands) =
        pure.reset(ledger_view(state), agent_id, timestamp)
      execute_commands(commands)

      actor.send(reply_to, Ok(Nil))
      actor.continue(with_counters(state, ledger))
    }

    GetTotalTokens(reply_to, agent_id) -> {
      let total = pure.total_tokens(ledger_view(state), agent_id)
      actor.send(reply_to, total)
      actor.continue(state)
    }

    GetTotalToolCalls(reply_to, agent_id) -> {
      let total = pure.total_tool_calls(ledger_view(state), agent_id)
      actor.send(reply_to, total)
      actor.continue(state)
    }

    RecordLLMUsage(
      reply_to,
      principal_id,
      provider,
      model,
      prompt_tokens,
      completion_tokens,
      cost_usd,
    ) -> {
      let event =
        LLMUsage(
          principal_id: principal_id,
          provider: provider,
          model: model,
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          cost_usd: cost_usd,
          timestamp: state.now(),
        )
      persist_event(state, event)

      actor.send(reply_to, Nil)
      actor.continue(
        ActorState(..state, events: pure.add_usage_event(state.events, event)),
      )
    }

    RecordToolUsage(reply_to, principal_id, tool_name, ok) -> {
      let event =
        ToolUsage(
          principal_id: principal_id,
          tool_name: tool_name,
          ok: ok,
          timestamp: state.now(),
        )
      persist_event(state, event)

      actor.send(reply_to, Nil)
      actor.continue(
        ActorState(..state, events: pure.add_usage_event(state.events, event)),
      )
    }

    GetUsage(reply_to, principal_id) -> {
      actor.send(reply_to, pure.usage_for(state.events, principal_id))
      actor.continue(state)
    }

    GetAllUsage(reply_to) -> {
      actor.send(reply_to, state.events)
      actor.continue(state)
    }

    GetLLMCostWhere(reply_to, keep) -> {
      let total =
        list.fold(state.events, 0.0, fn(acc, event) {
          case event {
            LLMUsage(timestamp: timestamp, cost_usd: cost, ..) ->
              case keep(timestamp) {
                True -> acc +. cost
                False -> acc
              }
            ToolUsage(..) -> acc
          }
        })
      actor.send(reply_to, total)
      actor.continue(state)
    }

    GetDailyCost(reply_to, day) -> {
      actor.send(reply_to, pure.daily_cost(state.events, day))
      actor.continue(state)
    }

    GetDailyCostFor(reply_to, day, principal_id) -> {
      actor.send(reply_to, pure.daily_cost_for(state.events, day, principal_id))
      actor.continue(state)
    }

    RotateOldFiles(reply_to, now) -> {
      rotate_directory(state.directory, now)
      actor.send(reply_to, Nil)
      actor.continue(state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Persistence Helpers
// ============================================================================

/// Load every persisted event, oldest day first.
fn load_events(directory: String) -> List(UsageEvent) {
  case ffi_file_exists(directory) {
    Ok(False) -> []
    _ ->
      case ffi_list_dir(directory) {
        Error(_) -> []
        Ok(names) ->
          names
          |> list.filter(pure.is_jsonl_file)
          |> list.sort(string.compare)
          |> list.flat_map(fn(name) {
            load_events_file(directory <> "/" <> name)
          })
      }
  }
}

fn load_events_file(path: String) -> List(UsageEvent) {
  case ffi_read_file(path) {
    Error(_) -> []
    Ok(content) ->
      content
      |> string.split("\n")
      |> list.filter_map(pure.event_from_json)
  }
}

/// Delete trail files older than the retention window.
fn rotate_directory(directory: Option(String), now: Int) -> Nil {
  case directory {
    None -> Nil
    Some(directory) ->
      case ffi_list_dir(directory) {
        Error(_) -> Nil
        Ok(names) ->
          list.each(names, fn(name) {
            case pure.should_rotate(name, now) {
              True -> {
                let _ = ffi_delete_file(directory <> "/" <> name)
                Nil
              }
              False -> Nil
            }
          })
      }
  }
}

fn start_actor(
  initial_state: ActorState,
) -> Result(ResourceLedger, actor.StartError) {
  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start the resource ledger actor without persistence.
pub fn start() -> Result(ResourceLedger, actor.StartError) {
  start_actor(ActorState(
    counters: dict.new(),
    events: [],
    directory: None,
    now: ffi_current_timestamp,
  ))
}

/// Start the resource ledger actor, persisting the usage trail to `directory`.
///
/// On start all `<directory>/YYYY-MM-DD.jsonl` files are loaded, and files older
/// than 30 days are deleted.
pub fn start_persistent(
  directory: String,
) -> Result(ResourceLedger, actor.StartError) {
  start_persistent_with_clock(directory, ffi_current_timestamp)
}

/// Start the persistent ledger with an injectable clock (milliseconds).
pub fn start_persistent_with_clock(
  directory: String,
  now: fn() -> Int,
) -> Result(ResourceLedger, actor.StartError) {
  let _ = ffi_ensure_dir(directory)
  rotate_directory(Some(directory), now())

  start_actor(ActorState(
    counters: dict.new(),
    events: load_events(directory),
    directory: Some(directory),
    now: now,
  ))
}

/// Charge LLM tokens for an agent.
pub fn charge_llm(
  ledger: ResourceLedger,
  agent_id: String,
  prompt_tokens: Int,
  completion_tokens: Int,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: ChargeLLM(
    _,
    agent_id,
    prompt_tokens,
    completion_tokens,
  ))
}

/// Charge a tool call for an agent.
pub fn charge_tool(
  ledger: ResourceLedger,
  agent_id: String,
  tool_name: String,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: ChargeTool(_, agent_id, tool_name))
}

/// Charge storage operations for an agent.
pub fn charge_storage(
  ledger: ResourceLedger,
  agent_id: String,
  reads: Int,
  writes: Int,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: ChargeStorage(
    _,
    agent_id,
    reads,
    writes,
  ))
}

/// Charge CPU time for an agent.
pub fn charge_cpu(
  ledger: ResourceLedger,
  agent_id: String,
  cpu_time_ms: Int,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: ChargeCPU(_, agent_id, cpu_time_ms))
}

/// Get resource counters snapshot for an agent.
pub fn get_snapshot(
  ledger: ResourceLedger,
  agent_id: String,
) -> Result(ResourceCounters, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: GetSnapshot(_, agent_id))
}

/// Check if an agent has exceeded a quota.
pub fn check_quota(
  ledger: ResourceLedger,
  agent_id: String,
  resource: ResourceType,
  limit: Int,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: CheckQuota(
    _,
    agent_id,
    resource,
    limit,
  ))
}

/// Reset counters for an agent.
pub fn reset_counters(
  ledger: ResourceLedger,
  agent_id: String,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: ResetCounters(_, agent_id))
}

/// Get total token count for an agent.
pub fn get_total_tokens(ledger: ResourceLedger, agent_id: String) -> Int {
  actor.call(ledger, waiting: 1500, sending: GetTotalTokens(_, agent_id))
}

/// Get total tool calls count for an agent.
pub fn get_total_tool_calls(ledger: ResourceLedger, agent_id: String) -> Int {
  actor.call(ledger, waiting: 1500, sending: GetTotalToolCalls(_, agent_id))
}

/// Record a completed LLM call in the usage trail.
pub fn record_llm_usage(
  ledger: ResourceLedger,
  principal_id: String,
  provider: String,
  model: String,
  prompt_tokens: Int,
  completion_tokens: Int,
  cost_usd: Float,
) -> Nil {
  let _ =
    try_record_llm_usage(
      ledger,
      principal_id,
      provider,
      model,
      prompt_tokens,
      completion_tokens,
      cost_usd,
    )
  Nil
}

/// Record an LLM call, returning an error when the ledger is unavailable.
pub fn try_record_llm_usage(
  ledger: ResourceLedger,
  principal_id: String,
  provider: String,
  model: String,
  prompt_tokens: Int,
  completion_tokens: Int,
  cost_usd: Float,
) -> Result(Nil, String) {
  case
    safe_call.call(ledger, 1500, RecordLLMUsage(
      _,
      principal_id,
      provider,
      model,
      prompt_tokens,
      completion_tokens,
      cost_usd,
    ))
  {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("ledger unavailable")
  }
}

/// Record a tool invocation in the usage trail.
pub fn record_tool_usage(
  ledger: ResourceLedger,
  principal_id: String,
  tool_name: String,
  ok: Bool,
) -> Nil {
  let _ = try_record_tool_usage(ledger, principal_id, tool_name, ok)
  Nil
}

/// Record a tool call, returning an error when the ledger is unavailable.
pub fn try_record_tool_usage(
  ledger: ResourceLedger,
  principal_id: String,
  tool_name: String,
  ok: Bool,
) -> Result(Nil, String) {
  case
    safe_call.call(ledger, 1500, RecordToolUsage(_, principal_id, tool_name, ok))
  {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("ledger unavailable")
  }
}

/// Get the usage trail for one principal.
pub fn get_usage(
  ledger: ResourceLedger,
  principal_id: String,
) -> List(UsageEvent) {
  case safe_call.call(ledger, 1500, GetUsage(_, principal_id)) {
    Ok(events) -> events
    Error(_) -> []
  }
}

/// Sum the LLM cost of events whose timestamp satisfies `keep`, failing
/// explicitly when the ledger is unavailable.
pub fn try_llm_cost_where(
  ledger: ResourceLedger,
  keep: fn(Int) -> Bool,
) -> Result(Float, Nil) {
  case safe_call.call(ledger, 1500, GetLLMCostWhere(_, keep)) {
    Ok(total) -> Ok(total)
    Error(_) -> Error(Nil)
  }
}

/// Get the full usage trail with an explicit failure.
pub fn try_get_all_usage(
  ledger: ResourceLedger,
) -> Result(List(UsageEvent), Nil) {
  case safe_call.call(ledger, 1500, GetAllUsage) {
    Ok(events) -> Ok(events)
    Error(_) -> Error(Nil)
  }
}

pub fn get_all_usage(ledger: ResourceLedger) -> List(UsageEvent) {
  case safe_call.call(ledger, 1500, GetAllUsage) {
    Ok(events) -> events
    Error(_) -> []
  }
}

/// Get the total LLM cost for a UTC day.
pub fn get_daily_cost(ledger: ResourceLedger, day: String) -> Float {
  actor.call(ledger, waiting: 1500, sending: GetDailyCost(_, day))
}

/// Get the LLM cost for a UTC day for one principal.
pub fn get_daily_cost_for(
  ledger: ResourceLedger,
  day: String,
  principal_id: String,
) -> Float {
  actor.call(ledger, waiting: 1500, sending: GetDailyCostFor(
    _,
    day,
    principal_id,
  ))
}

/// Delete usage trail files older than the retention window.
pub fn rotate_old_files(ledger: ResourceLedger, now: Int) -> Nil {
  actor.call(ledger, waiting: 1500, sending: RotateOldFiles(_, now))
}

/// Stop the ledger actor.
pub fn stop(ledger: ResourceLedger) -> Nil {
  let _ = safe_call.call(ledger, 1500, Stop)
  Nil
}
