//// Resource Ledger — Pure Functions
////
//// Pure functions for resource accounting. No FFI, no side effects.
//// Functions take state and return new state + commands for the actor to execute.
////
//// ## Usage
////
//// ```gleam
//// let #(new_state, commands) = pure.charge(state, "agent_1", LLMTokensPrompt, 100)
//// ```

import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import supernova/core/resource_ledger/types.{
  type LedgerCommand, type LedgerError, type LedgerState, type ResourceCounters,
  type ResourceType, CPUTimeMs, EmitTelemetry, LLMTokensCompletion,
  LLMTokensPrompt, QuotaExceeded, ResourceCounters, StorageRead, StorageWrite,
  ToolCall, WriteAudit,
}

// ============================================================================
// Public API
// ============================================================================

/// Charge a resource to an agent.
///
/// Returns the updated state and commands to log the charge.
/// Creates a new counter if the agent doesn't exist yet.
pub fn charge(
  state: LedgerState,
  agent_id: String,
  resource: ResourceType,
  amount: Int,
  timestamp: Int,
) -> #(LedgerState, List(LedgerCommand)) {
  // Get or create counters for this agent
  let counters = case dict.get(state.counters, agent_id) {
    Ok(existing) -> existing
    Error(_) -> empty_counters()
  }

  // Update the appropriate counter
  let new_counters = case resource {
    LLMTokensPrompt ->
      ResourceCounters(
        ..counters,
        llm_tokens_prompt: counters.llm_tokens_prompt + amount,
      )
    LLMTokensCompletion ->
      ResourceCounters(
        ..counters,
        llm_tokens_completion: counters.llm_tokens_completion + amount,
      )
    ToolCall(tool_name) -> {
      let current_count =
        dict.get(counters.tool_calls, tool_name)
        |> result.unwrap(0)
      let new_tool_calls =
        dict.insert(counters.tool_calls, tool_name, current_count + amount)
      ResourceCounters(..counters, tool_calls: new_tool_calls)
    }
    StorageRead ->
      ResourceCounters(
        ..counters,
        storage_reads: counters.storage_reads + amount,
      )
    StorageWrite ->
      ResourceCounters(
        ..counters,
        storage_writes: counters.storage_writes + amount,
      )
    CPUTimeMs ->
      ResourceCounters(..counters, cpu_time_ms: counters.cpu_time_ms + amount)
  }

  // Update state
  let new_state =
    types.LedgerState(counters: dict.insert(
      state.counters,
      agent_id,
      new_counters,
    ))

  // Generate commands
  let resource_name = resource_type_to_string(resource)
  let commands = [
    WriteAudit(agent_id, resource_name, amount, timestamp),
    EmitTelemetry("ledger:charge", [
      #("agent_id", agent_id),
      #("resource", resource_name),
      #("amount", int.to_string(amount)),
    ]),
  ]

  #(new_state, commands)
}

/// Get a snapshot of resource counters for an agent.
///
/// Returns None if the agent doesn't exist.
pub fn snapshot(
  state: LedgerState,
  agent_id: String,
) -> Result(ResourceCounters, LedgerError) {
  case dict.get(state.counters, agent_id) {
    Ok(counters) -> Ok(counters)
    Error(_) -> Error(types.AgentNotFound(agent_id))
  }
}

/// Check if an agent has exceeded a quota for a specific resource.
///
/// Returns Ok(Nil) if within quota, Error(QuotaExceeded) if exceeded.
pub fn quota_exceeded(
  state: LedgerState,
  agent_id: String,
  resource: ResourceType,
  limit: Int,
) -> Result(Nil, LedgerError) {
  case dict.get(state.counters, agent_id) {
    Ok(counters) -> {
      let current = get_resource_value(counters, resource)
      case current >= limit {
        True -> {
          let resource_name = resource_type_to_string(resource)
          Error(QuotaExceeded(agent_id, resource_name, current, limit))
        }
        False -> Ok(Nil)
      }
    }
    Error(_) -> Ok(Nil)
  }
}

/// Reset counters for a specific agent.
///
/// Returns the updated state with empty counters for that agent.
pub fn reset(
  state: LedgerState,
  agent_id: String,
  timestamp: Int,
) -> #(LedgerState, List(LedgerCommand)) {
  let new_counters = empty_counters()
  let new_state =
    types.LedgerState(counters: dict.insert(
      state.counters,
      agent_id,
      new_counters,
    ))

  let commands = [
    EmitTelemetry("ledger:reset", [#("agent_id", agent_id)]),
    WriteAudit(agent_id, "RESET", 0, timestamp),
  ]

  #(new_state, commands)
}

/// Get total token count (prompt + completion) for an agent.
pub fn total_tokens(state: LedgerState, agent_id: String) -> Int {
  case dict.get(state.counters, agent_id) {
    Ok(counters) -> counters.llm_tokens_prompt + counters.llm_tokens_completion
    Error(_) -> 0
  }
}

/// Get total tool calls count for an agent (across all tools).
pub fn total_tool_calls(state: LedgerState, agent_id: String) -> Int {
  case dict.get(state.counters, agent_id) {
    Ok(counters) ->
      counters.tool_calls
      |> dict.values()
      |> list.fold(0, fn(acc, count) { acc + count })
    Error(_) -> 0
  }
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Create empty resource counters.
fn empty_counters() -> ResourceCounters {
  ResourceCounters(
    llm_tokens_prompt: 0,
    llm_tokens_completion: 0,
    tool_calls: dict.new(),
    storage_reads: 0,
    storage_writes: 0,
    cpu_time_ms: 0,
  )
}

/// Convert ResourceType to a string representation.
fn resource_type_to_string(resource: ResourceType) -> String {
  case resource {
    LLMTokensPrompt -> "llm_tokens_prompt"
    LLMTokensCompletion -> "llm_tokens_completion"
    ToolCall(tool_name) -> "tool_call:" <> tool_name
    StorageRead -> "storage_read"
    StorageWrite -> "storage_write"
    CPUTimeMs -> "cpu_time_ms"
  }
}

/// Get the current value for a specific resource from counters.
fn get_resource_value(counters: ResourceCounters, resource: ResourceType) -> Int {
  case resource {
    LLMTokensPrompt -> counters.llm_tokens_prompt
    LLMTokensCompletion -> counters.llm_tokens_completion
    ToolCall(tool_name) ->
      dict.get(counters.tool_calls, tool_name)
      |> result.unwrap(0)
    StorageRead -> counters.storage_reads
    StorageWrite -> counters.storage_writes
    CPUTimeMs -> counters.cpu_time_ms
  }
}
