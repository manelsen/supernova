//// Audit Log — Pure Types
////
//// Pure data structures for operational audit logging.
//// No FFI, no side effects.
//// These types define the domain model for append-only audit entries.

import gleam/int

// ============================================================================
// Types
// ============================================================================

/// Result of an audited operation.
pub type AuditResult {
  /// Operation completed successfully
  AuditSuccess
  /// Operation failed
  AuditFailure
  /// Operation was denied by policy
  AuditDenied
}

/// A single audit log entry.
pub type AuditEntry {
  AuditEntry(
    /// When the operation occurred (milliseconds since epoch)
    timestamp: Int,
    /// The agent that performed the operation
    agent_id: String,
    /// The type of operation (e.g., "tool_call", "llm_request", "io_read", "spawn")
    operation: String,
    /// The target of the operation (e.g., tool name, file path, model name)
    target: String,
    /// The result of the operation
    result: AuditResult,
    /// Additional details about the operation
    details: String,
  )
}

/// Filter for querying audit entries.
pub type AuditFilter {
  AuditFilter(
    /// Filter by operation type (empty = all)
    operation: String,
    /// Filter by target (empty = all)
    target: String,
    /// Filter by result (None = all)
    result: Result(AuditResult, Nil),
  )
}

/// Command pattern for I/O operations.
/// Pure functions return commands; the actor executes them.
pub type AuditCommand {
  /// Write entry to rotating log file
  WriteToFile(entry: AuditEntry, workspace_root: String)
}

/// Error type for audit log operations.
pub type AuditError {
  /// Agent not found in audit log
  AgentNotFound(agent_id: String)
}

/// The audit log state maintained by the actor.
pub type AuditLogState {
  AuditLogState(
    /// In-memory buffer of recent entries per agent
    entries: List(AuditEntry),
    /// Maximum entries to keep in memory
    max_entries: Int,
  )
}

// ============================================================================
// Default Values
// ============================================================================

/// Create an initial empty audit log state.
pub fn initial_state(max_entries: Int) -> AuditLogState {
  AuditLogState(entries: [], max_entries: max_entries)
}

/// Create a default filter that matches all entries.
pub fn default_filter() -> AuditFilter {
  AuditFilter(operation: "", target: "", result: Error(Nil))
}

/// Create a filter for a specific operation type.
pub fn operation_filter(operation: String) -> AuditFilter {
  AuditFilter(operation: operation, target: "", result: Error(Nil))
}

/// Create a filter for a specific result type.
pub fn result_filter(result: AuditResult) -> AuditFilter {
  AuditFilter(operation: "", target: "", result: Ok(result))
}

// ============================================================================
// Convenience Constructors
// ============================================================================

/// Create a success audit entry.
pub fn success_entry(
  timestamp: Int,
  agent_id: String,
  operation: String,
  target: String,
  details: String,
) -> AuditEntry {
  AuditEntry(
    timestamp: timestamp,
    agent_id: agent_id,
    operation: operation,
    target: target,
    result: AuditSuccess,
    details: details,
  )
}

/// Create a failure audit entry.
pub fn failure_entry(
  timestamp: Int,
  agent_id: String,
  operation: String,
  target: String,
  details: String,
) -> AuditEntry {
  AuditEntry(
    timestamp: timestamp,
    agent_id: agent_id,
    operation: operation,
    target: target,
    result: AuditFailure,
    details: details,
  )
}

/// Create a denied audit entry.
pub fn denied_entry(
  timestamp: Int,
  agent_id: String,
  operation: String,
  target: String,
  details: String,
) -> AuditEntry {
  AuditEntry(
    timestamp: timestamp,
    agent_id: agent_id,
    operation: operation,
    target: target,
    result: AuditDenied,
    details: details,
  )
}

// ============================================================================
// Formatting
// ============================================================================

/// Format an audit result to string.
pub fn result_to_string(result: AuditResult) -> String {
  case result {
    AuditSuccess -> "success"
    AuditFailure -> "failure"
    AuditDenied -> "denied"
  }
}

/// Format an audit entry to a log line.
pub fn format_entry(entry: AuditEntry) -> String {
  int.to_string(entry.timestamp)
  <> " | "
  <> escape_field(entry.agent_id)
  <> " | "
  <> escape_field(entry.operation)
  <> " | "
  <> escape_field(entry.target)
  <> " | "
  <> result_to_string(entry.result)
  <> " | "
  <> escape_field(entry.details)
}

/// Keep one audit event on one line with six fields. Targets can come from
/// model-chosen paths, so line breaks and the field separator are escaped.
/// Ordinary values are unchanged.
@external(erlang, "supernova_audit_ffi", "escape_field")
pub fn escape_field(value: String) -> String
