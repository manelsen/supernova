//// Audit Log — Pure Functions
////
//// Pure functions for audit log management. No FFI, no side effects.
//// Functions take state and return new state + commands for the actor to execute.
////
//// ## Usage
////
//// ```gleam
//// let #(new_state, commands) = pure.log(state, entry, "workspaces")
//// let entries = pure.query(state, "agent_1", filter)
//// let recent = pure.recent(state, "agent_1", 10)
//// ```

import gleam/list
import gleam/string
import supernova/core/audit_log/types.{
  type AuditCommand, type AuditEntry, type AuditFilter, type AuditLogState,
  type AuditResult, AuditLogState, WriteToFile,
}

// ============================================================================
// Public API
// ============================================================================

/// Log an audit entry.
///
/// Appends the entry to the in-memory buffer and returns a command
/// to write it to the rotating log file.
pub fn log(
  state: AuditLogState,
  entry: AuditEntry,
  workspace_root: String,
) -> #(AuditLogState, List(AuditCommand)) {
  // Add to in-memory buffer (prepend for O(1))
  let new_entries = [entry, ..state.entries]

  // Trim buffer if exceeding max
  let trimmed = case list.length(new_entries) > state.max_entries {
    True -> list.take(new_entries, state.max_entries)
    False -> new_entries
  }

  let new_state = AuditLogState(..state, entries: trimmed)
  let commands = [WriteToFile(entry: entry, workspace_root: workspace_root)]

  #(new_state, commands)
}

/// Query audit entries for an agent with a filter.
///
/// Returns entries matching the agent_id and filter criteria.
/// Entries are returned in reverse chronological order (newest first).
pub fn query(
  state: AuditLogState,
  agent_id: String,
  filter: AuditFilter,
) -> List(AuditEntry) {
  state.entries
  |> list.filter(fn(entry) { entry.agent_id == agent_id })
  |> list.filter(fn(entry) { matches_filter(entry, filter) })
}

/// Get recent audit entries for an agent.
///
/// Returns up to `limit` most recent entries for the given agent.
/// Entries are returned in reverse chronological order (newest first).
pub fn recent(
  state: AuditLogState,
  agent_id: String,
  limit: Int,
) -> List(AuditEntry) {
  state.entries
  |> list.filter(fn(entry) { entry.agent_id == agent_id })
  |> list.take(limit)
}

/// Get all entries in the buffer.
pub fn get_all(state: AuditLogState) -> List(AuditEntry) {
  state.entries
}

/// Get entries by operation type across all agents.
pub fn get_by_operation(
  state: AuditLogState,
  operation: String,
) -> List(AuditEntry) {
  list.filter(state.entries, fn(entry) { entry.operation == operation })
}

/// Get entries by result type across all agents.
pub fn get_by_result(
  state: AuditLogState,
  result: AuditResult,
) -> List(AuditEntry) {
  list.filter(state.entries, fn(entry) { entry.result == result })
}

/// Count entries for an agent.
pub fn count_for_agent(state: AuditLogState, agent_id: String) -> Int {
  state.entries
  |> list.filter(fn(entry) { entry.agent_id == agent_id })
  |> list.length
}

/// Count entries by result type for an agent.
pub fn count_by_result(
  state: AuditLogState,
  agent_id: String,
  result: AuditResult,
) -> Int {
  state.entries
  |> list.filter(fn(entry) {
    entry.agent_id == agent_id && entry.result == result
  })
  |> list.length
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Check if an entry matches a filter.
fn matches_filter(entry: AuditEntry, filter: AuditFilter) -> Bool {
  let op_matches = case filter.operation {
    "" -> True
    op -> entry.operation == op
  }

  let target_matches = case filter.target {
    "" -> True
    tgt -> string.contains(entry.target, tgt)
  }

  let result_matches = case filter.result {
    Ok(r) -> entry.result == r
    Error(_) -> True
  }

  op_matches && target_matches && result_matches
}
