//// Telemetry — Pure Functions
////
//// Pure functions for telemetry event emission. No FFI, no side effects.
//// Functions take state and return new state + commands for the actor to execute.
////
//// ## Usage
////
//// ```gleam
//// let #(new_state, commands) = pure.emit(state, "executor:start", timestamp, "agent_1", measurements, metadata)
//// ```

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import supernova/core/telemetry/types.{
  type TelemetryCommand, type TelemetryEvent, type TelemetryEventType,
  type TelemetryState, BlackboardFetch, BlackboardPost, ExecutorException,
  ExecutorStart, ExecutorStop, FormatOutput, LLMError, LLMRequest, LLMResponse,
  SessionCreated, SessionTerminated, SubagentFailed, SubagentFinished,
  SubagentSpawned, TelemetryEvent, TelemetryState, ToolException, ToolStart,
  ToolStop, WriteToLedger,
}

// ============================================================================
// Public API
// ============================================================================

/// Emit a telemetry event.
///
/// Creates a standardized event with timestamp, agent_id, measurements, and metadata.
/// Returns the updated state and commands for the actor to execute.
pub fn emit(
  state: TelemetryState,
  name: String,
  timestamp: Int,
  agent_id: String,
  measurements: Dict(String, String),
  metadata: Dict(String, String),
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  let event =
    TelemetryEvent(
      name: name,
      timestamp: timestamp,
      agent_id: agent_id,
      measurements: measurements,
      metadata: metadata,
    )

  let new_events = [event, ..state.events] |> list.take(state.max_events)
  let new_state = TelemetryState(..state, events: new_events)

  let commands = [
    WriteToLedger(agent_id, name, measurements),
    FormatOutput(event),
  ]

  #(new_state, commands, event)
}

/// Emit a typed telemetry event.
///
/// Convenience function that converts TelemetryEventType to string name.
pub fn emit_typed(
  state: TelemetryState,
  event_type: TelemetryEventType,
  timestamp: Int,
  agent_id: String,
  measurements: Dict(String, String),
  metadata: Dict(String, String),
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  let name = types.event_type_to_string(event_type)
  emit(state, name, timestamp, agent_id, measurements, metadata)
}

// ============================================================================
// Convenience Constructors — Executor Events
// ============================================================================

/// Emit executor:start event.
pub fn executor_start(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  session_id: String,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    ExecutorStart,
    timestamp,
    agent_id,
    dict.new(),
    dict.from_list([#("session_id", session_id)]),
  )
}

/// Emit executor:stop event.
pub fn executor_stop(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  duration_ms: Int,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    ExecutorStop,
    timestamp,
    agent_id,
    dict.from_list([#("duration_ms", int.to_string(duration_ms))]),
    dict.new(),
  )
}

/// Emit executor:exception event.
pub fn executor_exception(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  error: String,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    ExecutorException,
    timestamp,
    agent_id,
    dict.new(),
    dict.from_list([#("error", error)]),
  )
}

// ============================================================================
// Convenience Constructors — Tool Events
// ============================================================================

/// Emit tool:start event.
pub fn tool_start(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  tool_name: String,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    ToolStart,
    timestamp,
    agent_id,
    dict.new(),
    dict.from_list([#("tool_name", tool_name)]),
  )
}

/// Emit tool:stop event.
pub fn tool_stop(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  tool_name: String,
  duration_ms: Int,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    ToolStop,
    timestamp,
    agent_id,
    dict.from_list([#("duration_ms", int.to_string(duration_ms))]),
    dict.from_list([#("tool_name", tool_name)]),
  )
}

/// Emit tool:exception event.
pub fn tool_exception(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  tool_name: String,
  error: String,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    ToolException,
    timestamp,
    agent_id,
    dict.new(),
    dict.from_list([#("tool_name", tool_name), #("error", error)]),
  )
}

// ============================================================================
// Convenience Constructors — LLM Events
// ============================================================================

/// Emit llm:request event.
pub fn llm_request(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  model: String,
  provider: String,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    LLMRequest,
    timestamp,
    agent_id,
    dict.new(),
    dict.from_list([#("model", model), #("provider", provider)]),
  )
}

/// Emit llm:response event.
pub fn llm_response(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  model: String,
  tokens_prompt: Int,
  tokens_completion: Int,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    LLMResponse,
    timestamp,
    agent_id,
    dict.from_list([
      #("tokens_prompt", int.to_string(tokens_prompt)),
      #("tokens_completion", int.to_string(tokens_completion)),
    ]),
    dict.from_list([#("model", model)]),
  )
}

/// Emit llm:error event.
pub fn llm_error(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  model: String,
  error: String,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    LLMError,
    timestamp,
    agent_id,
    dict.new(),
    dict.from_list([#("model", model), #("error", error)]),
  )
}

// ============================================================================
// Convenience Constructors — Session Events
// ============================================================================

/// Emit session:created event.
pub fn session_created(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  session_id: String,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    SessionCreated,
    timestamp,
    agent_id,
    dict.new(),
    dict.from_list([#("session_id", session_id)]),
  )
}

/// Emit session:terminated event.
pub fn session_terminated(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  session_id: String,
  duration_ms: Int,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    SessionTerminated,
    timestamp,
    agent_id,
    dict.from_list([#("duration_ms", int.to_string(duration_ms))]),
    dict.from_list([#("session_id", session_id)]),
  )
}

// ============================================================================
// Convenience Constructors — Subagent Events
// ============================================================================

/// Emit subagent:spawned event.
pub fn subagent_spawned(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  child_agent_id: String,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    SubagentSpawned,
    timestamp,
    agent_id,
    dict.new(),
    dict.from_list([#("child_agent_id", child_agent_id)]),
  )
}

/// Emit subagent:finished event.
pub fn subagent_finished(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  child_agent_id: String,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    SubagentFinished,
    timestamp,
    agent_id,
    dict.new(),
    dict.from_list([#("child_agent_id", child_agent_id)]),
  )
}

/// Emit subagent:failed event.
pub fn subagent_failed(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  child_agent_id: String,
  error: String,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    SubagentFailed,
    timestamp,
    agent_id,
    dict.new(),
    dict.from_list([
      #("child_agent_id", child_agent_id),
      #("error", error),
    ]),
  )
}

// ============================================================================
// Convenience Constructors — Blackboard Events
// ============================================================================

/// Emit blackboard:post event.
pub fn blackboard_post(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  key: String,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    BlackboardPost,
    timestamp,
    agent_id,
    dict.new(),
    dict.from_list([#("key", key)]),
  )
}

/// Emit blackboard:fetch event.
pub fn blackboard_fetch(
  state: TelemetryState,
  timestamp: Int,
  agent_id: String,
  key: String,
) -> #(TelemetryState, List(TelemetryCommand), TelemetryEvent) {
  emit_typed(
    state,
    BlackboardFetch,
    timestamp,
    agent_id,
    dict.new(),
    dict.from_list([#("key", key)]),
  )
}

// ============================================================================
// State Management
// ============================================================================

/// Create initial telemetry state.
pub fn initial_state(max_events: Int) -> TelemetryState {
  TelemetryState(events: [], max_events: max_events)
}

/// Get recent events from the state.
pub fn get_events(state: TelemetryState) -> List(TelemetryEvent) {
  state.events
}

/// Get events filtered by agent_id.
pub fn get_events_by_agent(
  state: TelemetryState,
  agent_id: String,
) -> List(TelemetryEvent) {
  state.events
  |> list.filter(fn(e) { e.agent_id == agent_id })
}

/// Get events filtered by event name prefix (e.g., "executor:").
pub fn get_events_by_prefix(
  state: TelemetryState,
  prefix: String,
) -> List(TelemetryEvent) {
  state.events
  |> list.filter(fn(e) { string.starts_with(e.name, prefix) })
}

/// Format a telemetry event as a human-readable string.
pub fn format_event(event: TelemetryEvent) -> String {
  let measurements_str =
    event.measurements
    |> dict.to_list()
    |> list.map(fn(pair) { pair.0 <> "=" <> pair.1 })
    |> list.sort(fn(a, b) { string.compare(a, b) })
    |> string.join(" ")

  let metadata_str =
    event.metadata
    |> dict.to_list()
    |> list.map(fn(pair) { pair.0 <> "=" <> pair.1 })
    |> list.sort(fn(a, b) { string.compare(a, b) })
    |> string.join(" ")

  let base =
    "[telemetry] "
    <> event.name
    <> " ts="
    <> int.to_string(event.timestamp)
    <> " agent="
    <> event.agent_id

  case measurements_str == "", metadata_str == "" {
    True, True -> base
    True, False -> base <> " [" <> metadata_str <> "]"
    False, True -> base <> " " <> measurements_str
    False, False ->
      base <> " " <> measurements_str <> " [" <> metadata_str <> "]"
  }
}

import gleam/string
