//// Resource Ledger — Actor
////
//// Singleton actor that maintains resource consumption counters per agent.
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

import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import supernova/core/resource_ledger/pure
import supernova/core/resource_ledger/types.{
  type LedgerCommand, type LedgerError, type LedgerState, type ResourceCounters,
  type ResourceType, EmitTelemetry, LedgerState, WriteAudit,
}

// ============================================================================
// FFI — Timestamp and Audit (Erlang)
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
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running ledger actor.
pub type ResourceLedger =
  Subject(LedgerMessage)

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

/// Handle incoming messages and update state.
fn handle_message(
  state: LedgerState,
  message: LedgerMessage,
) -> actor.Next(LedgerState, LedgerMessage) {
  case message {
    ChargeLLM(reply_to, agent_id, prompt_tokens, completion_tokens) -> {
      let timestamp = ffi_current_timestamp()

      // Charge prompt tokens
      let #(state1, commands1) =
        pure.charge(
          state,
          agent_id,
          types.LLMTokensPrompt,
          prompt_tokens,
          timestamp,
        )
      execute_commands(commands1)

      // Charge completion tokens
      let #(state2, commands2) =
        pure.charge(
          state1,
          agent_id,
          types.LLMTokensCompletion,
          completion_tokens,
          timestamp,
        )
      execute_commands(commands2)

      actor.send(reply_to, Ok(Nil))
      actor.continue(state2)
    }

    ChargeTool(reply_to, agent_id, tool_name) -> {
      let timestamp = ffi_current_timestamp()
      let #(new_state, commands) =
        pure.charge(state, agent_id, types.ToolCall(tool_name), 1, timestamp)
      execute_commands(commands)

      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    ChargeStorage(reply_to, agent_id, reads, writes) -> {
      let timestamp = ffi_current_timestamp()

      // Charge reads
      let #(state1, commands1) =
        pure.charge(state, agent_id, types.StorageRead, reads, timestamp)
      execute_commands(commands1)

      // Charge writes
      let #(state2, commands2) =
        pure.charge(state1, agent_id, types.StorageWrite, writes, timestamp)
      execute_commands(commands2)

      actor.send(reply_to, Ok(Nil))
      actor.continue(state2)
    }

    ChargeCPU(reply_to, agent_id, cpu_time_ms) -> {
      let timestamp = ffi_current_timestamp()
      let #(new_state, commands) =
        pure.charge(state, agent_id, types.CPUTimeMs, cpu_time_ms, timestamp)
      execute_commands(commands)

      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    GetSnapshot(reply_to, agent_id) -> {
      let result = pure.snapshot(state, agent_id)
      actor.send(reply_to, result)
      actor.continue(state)
    }

    CheckQuota(reply_to, agent_id, resource, limit) -> {
      let result = pure.quota_exceeded(state, agent_id, resource, limit)
      actor.send(reply_to, result)
      actor.continue(state)
    }

    ResetCounters(reply_to, agent_id) -> {
      let timestamp = ffi_current_timestamp()
      let #(new_state, commands) = pure.reset(state, agent_id, timestamp)
      execute_commands(commands)

      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    GetTotalTokens(reply_to, agent_id) -> {
      let total = pure.total_tokens(state, agent_id)
      actor.send(reply_to, total)
      actor.continue(state)
    }

    GetTotalToolCalls(reply_to, agent_id) -> {
      let total = pure.total_tool_calls(state, agent_id)
      actor.send(reply_to, total)
      actor.continue(state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start the resource ledger actor.
pub fn start() -> Result(ResourceLedger, actor.StartError) {
  let initial_state = LedgerState(counters: dict.new())

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Charge LLM tokens for an agent.
pub fn charge_llm(
  ledger: ResourceLedger,
  agent_id: String,
  prompt_tokens: Int,
  completion_tokens: Int,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 5000, sending: ChargeLLM(
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
  actor.call(ledger, waiting: 5000, sending: ChargeTool(_, agent_id, tool_name))
}

/// Charge storage operations for an agent.
pub fn charge_storage(
  ledger: ResourceLedger,
  agent_id: String,
  reads: Int,
  writes: Int,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 5000, sending: ChargeStorage(
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
  actor.call(ledger, waiting: 5000, sending: ChargeCPU(_, agent_id, cpu_time_ms))
}

/// Get resource counters snapshot for an agent.
pub fn get_snapshot(
  ledger: ResourceLedger,
  agent_id: String,
) -> Result(ResourceCounters, LedgerError) {
  actor.call(ledger, waiting: 5000, sending: GetSnapshot(_, agent_id))
}

/// Check if an agent has exceeded a quota.
pub fn check_quota(
  ledger: ResourceLedger,
  agent_id: String,
  resource: ResourceType,
  limit: Int,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 5000, sending: CheckQuota(
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
  actor.call(ledger, waiting: 5000, sending: ResetCounters(_, agent_id))
}

/// Get total token count (prompt + completion) for an agent.
pub fn get_total_tokens(ledger: ResourceLedger, agent_id: String) -> Int {
  actor.call(ledger, waiting: 5000, sending: GetTotalTokens(_, agent_id))
}

/// Get total tool calls count for an agent.
pub fn get_total_tool_calls(ledger: ResourceLedger, agent_id: String) -> Int {
  actor.call(ledger, waiting: 5000, sending: GetTotalToolCalls(_, agent_id))
}

/// Stop the ledger actor.
pub fn stop(ledger: ResourceLedger) -> Nil {
  actor.call(ledger, waiting: 5000, sending: Stop)
}
