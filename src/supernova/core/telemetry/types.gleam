//// Telemetry — Pure Types
////
//// Pure data structures for standardized telemetry events. No FFI, no side effects.
//// Events follow a consistent schema: timestamp, agent_id, measurements, metadata.
////
//// ## Event Categories
////
//// - executor: start/stop/exception
//// - tool: start/stop/exception
//// - llm: request/response/error
//// - session: created/terminated
//// - subagent: spawned/finished/failed
//// - blackboard: post/fetch

import gleam/dict.{type Dict}
import gleam/list

// ============================================================================
// Types
// ============================================================================

/// Standardized telemetry event.
/// Every event includes timestamp, agent_id, measurements, and metadata.
pub type TelemetryEvent {
  TelemetryEvent(
    /// Event name (e.g., "executor:start", "llm:request")
    name: String,
    /// Timestamp in milliseconds
    timestamp: Int,
    /// Agent that produced the event
    agent_id: String,
    /// Numeric measurements (e.g., "duration_ms" -> "150")
    measurements: Dict(String, String),
    /// Arbitrary metadata (e.g., "model" -> "gpt-4")
    metadata: Dict(String, String),
  )
}

/// Standardized event categories for type-safe event construction.
pub type TelemetryEventType {
  // Executor events
  ExecutorStart
  ExecutorStop
  ExecutorException
  // Tool events
  ToolStart
  ToolStop
  ToolException
  // LLM events
  LLMRequest
  LLMResponse
  LLMError
  // Session events
  SessionCreated
  SessionTerminated
  // Sub-agent events
  SubagentSpawned
  SubagentFinished
  SubagentFailed
  // Blackboard events
  BlackboardPost
  BlackboardFetch
}

/// Command pattern for I/O operations.
/// Pure functions return commands; the actor executes them.
pub type TelemetryCommand {
  /// Write event to the resource ledger
  WriteToLedger(
    agent_id: String,
    event_name: String,
    measurements: Dict(String, String),
  )
  /// Format and output the event (stdout, log, etc.)
  FormatOutput(event: TelemetryEvent)
}

/// The telemetry state maintained by the actor.
pub type TelemetryState {
  TelemetryState(
    /// Buffer of recent events (ring buffer style)
    events: List(TelemetryEvent),
    /// Maximum events to keep in buffer
    max_events: Int,
  )
}

/// Errors that can occur in telemetry operations.
pub type TelemetryError {
  /// Invalid event name (not in allowed categories)
  InvalidEventName(name: String)
  /// Missing required metadata field
  MissingMetadata(field: String)
  /// Ledger integration error
  LedgerError(reason: String)
}

// ============================================================================
// Event Name Constants
// ============================================================================

/// Convert a TelemetryEventType to its string name.
pub fn event_type_to_string(event_type: TelemetryEventType) -> String {
  case event_type {
    ExecutorStart -> "executor:start"
    ExecutorStop -> "executor:stop"
    ExecutorException -> "executor:exception"
    ToolStart -> "tool:start"
    ToolStop -> "tool:stop"
    ToolException -> "tool:exception"
    LLMRequest -> "llm:request"
    LLMResponse -> "llm:response"
    LLMError -> "llm:error"
    SessionCreated -> "session:created"
    SessionTerminated -> "session:terminated"
    SubagentSpawned -> "subagent:spawned"
    SubagentFinished -> "subagent:finished"
    SubagentFailed -> "subagent:failed"
    BlackboardPost -> "blackboard:post"
    BlackboardFetch -> "blackboard:fetch"
  }
}

/// List of all valid event names.
pub fn valid_event_names() -> List(String) {
  [
    "executor:start",
    "executor:stop",
    "executor:exception",
    "tool:start",
    "tool:stop",
    "tool:exception",
    "llm:request",
    "llm:response",
    "llm:error",
    "session:created",
    "session:terminated",
    "subagent:spawned",
    "subagent:finished",
    "subagent:failed",
    "blackboard:post",
    "blackboard:fetch",
  ]
}

/// Check if an event name is valid.
pub fn is_valid_event_name(name: String) -> Bool {
  valid_event_names()
  |> list.any(fn(valid) { valid == name })
}
