//// Syscall — Pure Types
////
//// Formal interface for all agent→kernel interactions.
//// No FFI, no side effects.
//// Every agent interaction with system resources goes through these types.

import gleam/dict.{type Dict}
import gleam/set.{type Set}

// ============================================================================
// Syscall Operations
// ============================================================================

/// All operations an agent can invoke via the syscall interface.
pub type SyscallOp {
  /// Spawn a new sub-agent with the given config JSON
  SpawnAgent(config: String)
  /// Kill a running agent by ID
  KillAgent(target_id: String)
  /// Query world model facts matching a content pattern
  ReadWorld(content_pattern: String)
  /// Assert a new fact into the world model
  WriteWorld(content: String, confidence: Float)
  /// Read a file at the given path (subject to WorkspacePolicy)
  ReadFile(path: String)
  /// Write content to a file (subject to WorkspacePolicy)
  WriteFile(path: String, content: String)
  /// Schedule a task with a delay in milliseconds
  Schedule(task_id: String, delay_ms: Int)
  /// Cancel a previously scheduled task
  CancelSchedule(task_id: String)
  /// Get current budget info for the calling agent
  GetBudget
  /// Emit an event for observability / inter-agent messaging
  EmitEvent(event_type: String, payload: String)
}

// ============================================================================
// Syscall Results
// ============================================================================

/// The result of a syscall invocation.
pub type SyscallResult {
  /// Syscall succeeded; data contains operation-specific output
  SyscallOk(data: String)
  /// Syscall denied by authentication, WorkspacePolicy, or BudgetPolicy
  SyscallDenied(reason: String)
  /// Syscall failed during execution
  SyscallFailed(message: String)
}

// ============================================================================
// Commands (pure → actor)
// ============================================================================

/// Result type classification for audit commands.
pub type SyscallAuditResult {
  AuditOk
  AuditDenied
  AuditFailed
}

/// Commands returned by pure functions for the actor to execute.
pub type SyscallCommand {
  /// Record a syscall in the audit log
  RecordAudit(
    agent_id: String,
    operation: String,
    target: String,
    result_type: SyscallAuditResult,
    details: String,
    timestamp: Int,
  )
}

// ============================================================================
// State
// ============================================================================

/// The syscall gateway state maintained by the actor.
pub type SyscallState {
  SyscallState(
    /// Agents allowed to make syscalls (registered via kernel)
    registered_agents: Set(String),
    /// Per-agent syscall invocation count (for observability)
    syscall_count: Dict(String, Int),
  )
}

// ============================================================================
// Initial State & Helpers
// ============================================================================

/// Create the initial empty syscall state.
pub fn initial_state() -> SyscallState {
  SyscallState(registered_agents: set.new(), syscall_count: dict.new())
}

/// Convert a syscall operation to a string name for logging.
pub fn op_to_string(op: SyscallOp) -> String {
  case op {
    SpawnAgent(_) -> "spawn_agent"
    KillAgent(_) -> "kill_agent"
    ReadWorld(_) -> "read_world"
    WriteWorld(_, _) -> "write_world"
    ReadFile(_) -> "read_file"
    WriteFile(_, _) -> "write_file"
    Schedule(_, _) -> "schedule"
    CancelSchedule(_) -> "cancel_schedule"
    GetBudget -> "get_budget"
    EmitEvent(_, _) -> "emit_event"
  }
}

/// Extract the primary target string from a syscall operation.
pub fn op_target(op: SyscallOp) -> String {
  case op {
    SpawnAgent(config) -> config
    KillAgent(target_id) -> target_id
    ReadWorld(pattern) -> pattern
    WriteWorld(content, _) -> content
    ReadFile(path) -> path
    WriteFile(path, _) -> path
    Schedule(task_id, _) -> task_id
    CancelSchedule(task_id) -> task_id
    GetBudget -> "budget"
    EmitEvent(event_type, _) -> event_type
  }
}

/// Convert SyscallAuditResult to a string.
pub fn audit_result_to_string(r: SyscallAuditResult) -> String {
  case r {
    AuditOk -> "ok"
    AuditDenied -> "denied"
    AuditFailed -> "failed"
  }
}
