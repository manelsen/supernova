//// Audit Log — Actor
////
//// Singleton actor that manages append-only audit log entries.
//// Delegates pure logic to the pure module, executes side effects via FFI.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(log) = actor.start("workspaces")
//// let assert Ok(_) = actor.log_entry(log, entry)
//// let entries = actor.query(log, "agent_1", filter)
//// actor.stop(log)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import supernova/core/audit_log/pure
import supernova/core/audit_log/types.{
  type AuditCommand, type AuditEntry, type AuditFilter, type AuditLogState,
  WriteToFile,
}

// ============================================================================
// FFI — File Write (Erlang)
// ============================================================================
@external(erlang, "supernova_audit_ffi", "write_audit_entry")
fn ffi_write_audit_entry(
  agent_id: String,
  log_line: String,
  workspace_root: String,
) -> Result(Nil, String)

// ============================================================================
// Types
// ============================================================================

/// Messages that the audit log actor handles.
pub type AuditMessage {
  /// Log an audit entry
  LogEntry(reply_to: Subject(Nil), entry: AuditEntry)
  /// Query entries for an agent with a filter
  QueryEntries(
    reply_to: Subject(List(AuditEntry)),
    agent_id: String,
    filter: AuditFilter,
  )
  /// Get recent entries for an agent
  RecentEntries(
    reply_to: Subject(List(AuditEntry)),
    agent_id: String,
    limit: Int,
  )
  /// Get all entries
  GetAllEntries(reply_to: Subject(List(AuditEntry)))
  /// Get entries by operation type
  GetByOperation(reply_to: Subject(List(AuditEntry)), operation: String)
  /// Count entries for an agent
  CountForAgent(reply_to: Subject(Int), agent_id: String)
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running audit log actor.
pub type AuditLog =
  Subject(AuditMessage)

/// Internal state with workspace root.
type ActorState {
  ActorState(state: AuditLogState, workspace_root: String)
}

// ============================================================================
// Command Execution
// ============================================================================

/// Execute a list of commands returned by pure functions.
fn execute_commands(commands: List(AuditCommand)) -> Nil {
  list.each(commands, fn(cmd) {
    case cmd {
      WriteToFile(entry, workspace_root) -> {
        let log_line = types.format_entry(entry)
        let _ = ffi_write_audit_entry(entry.agent_id, log_line, workspace_root)
        Nil
      }
    }
  })
}

// ============================================================================
// Actor Handler
// ============================================================================

/// Handle incoming messages and update state.
fn handle_message(
  actor_state: ActorState,
  message: AuditMessage,
) -> actor.Next(ActorState, AuditMessage) {
  case message {
    LogEntry(reply_to, entry) -> {
      let #(new_state, commands) =
        pure.log(actor_state.state, entry, actor_state.workspace_root)
      execute_commands(commands)

      actor.send(reply_to, Nil)
      actor.continue(ActorState(..actor_state, state: new_state))
    }

    QueryEntries(reply_to, agent_id, filter) -> {
      let entries = pure.query(actor_state.state, agent_id, filter)
      actor.send(reply_to, entries)
      actor.continue(actor_state)
    }

    RecentEntries(reply_to, agent_id, limit) -> {
      let entries = pure.recent(actor_state.state, agent_id, limit)
      actor.send(reply_to, entries)
      actor.continue(actor_state)
    }

    GetAllEntries(reply_to) -> {
      let entries = pure.get_all(actor_state.state)
      actor.send(reply_to, entries)
      actor.continue(actor_state)
    }

    GetByOperation(reply_to, operation) -> {
      let entries = pure.get_by_operation(actor_state.state, operation)
      actor.send(reply_to, entries)
      actor.continue(actor_state)
    }

    CountForAgent(reply_to, agent_id) -> {
      let count = pure.count_for_agent(actor_state.state, agent_id)
      actor.send(reply_to, count)
      actor.continue(actor_state)
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

/// Start the audit log actor with default capacity (10000 entries).
pub fn start(workspace_root: String) -> Result(AuditLog, actor.StartError) {
  start_with_capacity(workspace_root, 10_000)
}

/// Start the audit log actor with a custom buffer capacity.
pub fn start_with_capacity(
  workspace_root: String,
  max_entries: Int,
) -> Result(AuditLog, actor.StartError) {
  let initial_state =
    ActorState(
      state: types.initial_state(max_entries),
      workspace_root: workspace_root,
    )

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Log an audit entry.
///
/// Appends the entry to the in-memory buffer and writes to the rotating log file.
pub fn log_entry(log: AuditLog, entry: AuditEntry) -> Nil {
  actor.call(log, waiting: 5000, sending: LogEntry(_, entry))
}

/// Query audit entries for an agent with a filter.
///
/// Returns entries matching the agent_id and filter criteria.
pub fn query(
  log: AuditLog,
  agent_id: String,
  filter: AuditFilter,
) -> List(AuditEntry) {
  actor.call(log, waiting: 5000, sending: QueryEntries(_, agent_id, filter))
}

/// Get recent audit entries for an agent.
///
/// Returns up to `limit` most recent entries for the given agent.
pub fn recent(log: AuditLog, agent_id: String, limit: Int) -> List(AuditEntry) {
  actor.call(log, waiting: 5000, sending: RecentEntries(_, agent_id, limit))
}

/// Get all entries in the buffer.
pub fn get_all(log: AuditLog) -> List(AuditEntry) {
  actor.call(log, waiting: 5000, sending: GetAllEntries)
}

/// Get entries by operation type across all agents.
pub fn get_by_operation(log: AuditLog, operation: String) -> List(AuditEntry) {
  actor.call(log, waiting: 5000, sending: GetByOperation(_, operation))
}

/// Count entries for an agent.
pub fn count_for_agent(log: AuditLog, agent_id: String) -> Int {
  actor.call(log, waiting: 5000, sending: CountForAgent(_, agent_id))
}

/// Stop the audit log actor.
pub fn stop(log: AuditLog) -> Nil {
  actor.call(log, waiting: 5000, sending: Stop)
}
