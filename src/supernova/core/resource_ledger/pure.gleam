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
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import supernova/core/resource_ledger/types.{
  type LedgerCommand, type LedgerError, type LedgerState, type ResourceCounters,
  type ResourceType, type UsageEvent, CPUTimeMs, EmitTelemetry,
  LLMTokensCompletion, LLMTokensPrompt, LLMUsage, QuotaExceeded,
  ResourceCounters, StorageRead, StorageWrite, ToolCall, ToolUsage, WriteAudit,
}
import supernova/llm/pricing

/// Files older than this many days are rotated away on actor start.
const retention_days: Int = 30

const milliseconds_per_day: Int = 86_400_000

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
fn get_resource_value(
  counters: ResourceCounters,
  resource: ResourceType,
) -> Int {
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

// ============================================================================
// Usage Trail
// ============================================================================

/// Append an event to the usage trail.
pub fn add_usage_event(
  events: List(UsageEvent),
  event: UsageEvent,
) -> List(UsageEvent) {
  list.append(events, [event])
}

/// All events belonging to a principal, in recording order.
pub fn usage_for(
  events: List(UsageEvent),
  principal_id: String,
) -> List(UsageEvent) {
  list.filter(events, fn(event) { event_principal_id(event) == principal_id })
}

/// Sum of LLM costs for a UTC day, across all principals.
pub fn daily_cost(events: List(UsageEvent), day: String) -> Float {
  events
  |> list.filter(fn(event) { event_day(event) == day })
  |> total_cost
}

/// Sum of LLM costs for a UTC day, restricted to one principal.
pub fn daily_cost_for(
  events: List(UsageEvent),
  day: String,
  principal_id: String,
) -> Float {
  events
  |> usage_for(principal_id)
  |> list.filter(fn(event) { event_day(event) == day })
  |> total_cost
}

/// Whether the event is an LLM usage event (the only costed kind).
pub fn is_costed(event: UsageEvent) -> Bool {
  case event {
    LLMUsage(..) -> True
    ToolUsage(..) -> False
  }
}

/// The stored day key (UTC) of an event.
pub fn event_day(event: UsageEvent) -> String {
  pricing.day_key(event_timestamp(event), "UTC")
}

/// The wall-clock timestamp of an event.
pub fn event_timestamp(event: UsageEvent) -> Int {
  case event {
    LLMUsage(timestamp: timestamp, ..) -> timestamp
    ToolUsage(timestamp: timestamp, ..) -> timestamp
  }
}

/// The principal that caused an event.
pub fn event_principal_id(event: UsageEvent) -> String {
  case event {
    LLMUsage(principal_id: principal_id, ..) -> principal_id
    ToolUsage(principal_id: principal_id, ..) -> principal_id
  }
}

// ============================================================================
// Serialisation (JSON Lines)
// ============================================================================

/// Whether a directory entry is a usage trail file.
pub fn is_jsonl_file(name: String) -> Bool {
  string.ends_with(name, ".jsonl")
}

/// Whether an event is still inside the retention window.
pub fn event_within_retention(event: UsageEvent, now_ms: Int) -> Bool {
  event_timestamp(event) >= now_ms - { retention_days * milliseconds_per_day }
}

/// Whether a usage trail file should be deleted at `now_ms`.
///
/// Files are named `YYYY-MM-DD.jsonl`; ISO dates sort lexicographically, so the
/// comparison is safe. Files exactly `retention_days` old are kept.
pub fn should_rotate(name: String, now_ms: Int) -> Bool {
  case is_jsonl_file(name) {
    True -> {
      let cutoff =
        pricing.day_key(
          now_ms - { retention_days * milliseconds_per_day },
          "UTC",
        )
      string.compare(string.slice(name, 0, 10), cutoff) == order.Lt
    }
    False -> False
  }
}

/// The name of the trail file an event belongs to.
pub fn event_file_name(event: UsageEvent) -> String {
  event_day(event) <> ".jsonl"
}

/// Encode an event as a single JSON line (no trailing newline).
pub fn event_to_json(event: UsageEvent) -> String {
  case event {
    LLMUsage(
      principal_id: principal_id,
      provider: provider,
      model: model,
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      cost_usd: cost_usd,
      timestamp: timestamp,
      call_id: call_id,
    ) ->
      json.object([
        #("type", json.string("llm")),
        #("principal_id", json.string(principal_id)),
        #("provider", json.string(provider)),
        #("model", json.string(model)),
        #("prompt_tokens", json.int(prompt_tokens)),
        #("completion_tokens", json.int(completion_tokens)),
        #("cost_usd", json.float(cost_usd)),
        #("timestamp", json.int(timestamp)),
        #("call_id", json.string(call_id)),
      ])
    ToolUsage(
      principal_id: principal_id,
      tool_name: tool_name,
      ok: ok,
      timestamp: timestamp,
    ) ->
      json.object([
        #("type", json.string("tool")),
        #("principal_id", json.string(principal_id)),
        #("tool_name", json.string(tool_name)),
        #("ok", json.bool(ok)),
        #("timestamp", json.int(timestamp)),
      ])
  }
  |> json.to_string
}

/// Decode a single JSON line into an event. Malformed lines are rejected.
pub fn event_from_json(line: String) -> Result(UsageEvent, Nil) {
  case json.parse(from: line, using: raw_usage_event_decoder()) {
    Ok(raw) -> raw_to_event(raw)
    Error(_) -> Error(Nil)
  }
}

// ============================================================================
// Internal Helpers — Usage Trail
// ============================================================================

fn total_cost(events: List(UsageEvent)) -> Float {
  list.fold(events, 0.0, fn(total, event) {
    case event {
      LLMUsage(cost_usd: cost_usd, ..) -> total +. cost_usd
      ToolUsage(..) -> total
    }
  })
}

type RawUsageEvent {
  RawUsageEvent(
    kind: String,
    principal_id: String,
    provider: String,
    model: String,
    prompt_tokens: Int,
    completion_tokens: Int,
    cost_usd: Float,
    tool_name: String,
    ok: Bool,
    timestamp: Int,
    call_id: String,
  )
}

fn raw_usage_event_decoder() -> decode.Decoder(RawUsageEvent) {
  use kind <- decode.field("type", decode.string)
  use principal_id <- decode.field("principal_id", decode.string)
  use provider <- decode.optional_field("provider", "", decode.string)
  use model <- decode.optional_field("model", "", decode.string)
  use prompt_tokens <- decode.optional_field("prompt_tokens", 0, decode.int)
  use completion_tokens <- decode.optional_field(
    "completion_tokens",
    0,
    decode.int,
  )
  use cost_usd <- decode.optional_field("cost_usd", 0.0, decode.float)
  use tool_name <- decode.optional_field("tool_name", "", decode.string)
  use ok <- decode.optional_field("ok", False, decode.bool)
  use timestamp <- decode.field("timestamp", decode.int)
  use call_id <- decode.optional_field("call_id", "", decode.string)

  decode.success(RawUsageEvent(
    kind: kind,
    principal_id: principal_id,
    provider: provider,
    model: model,
    prompt_tokens: prompt_tokens,
    completion_tokens: completion_tokens,
    cost_usd: cost_usd,
    tool_name: tool_name,
    ok: ok,
    timestamp: timestamp,
    call_id: call_id,
  ))
}

fn raw_to_event(raw: RawUsageEvent) -> Result(UsageEvent, Nil) {
  case raw.kind {
    "llm" ->
      Ok(LLMUsage(
        principal_id: raw.principal_id,
        provider: raw.provider,
        model: raw.model,
        prompt_tokens: raw.prompt_tokens,
        completion_tokens: raw.completion_tokens,
        cost_usd: raw.cost_usd,
        timestamp: raw.timestamp,
        call_id: raw.call_id,
      ))
    "tool" ->
      Ok(ToolUsage(
        principal_id: raw.principal_id,
        tool_name: raw.tool_name,
        ok: raw.ok,
        timestamp: raw.timestamp,
      ))
    _ -> Error(Nil)
  }
}
