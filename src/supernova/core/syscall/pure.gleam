//// Syscall — Pure Functions
////
//// Pure functions for the syscall gateway. No FFI, no side effects.
//// Handles authentication and syscall count tracking.
//// The actor layer handles WorkspacePolicy, BudgetPolicy, execution, and AuditLog.
////
//// ## Pipeline
////
//// 1. authenticate — is the agent registered?
//// 2. [actor] workspace policy — for file operations
//// 3. [actor] budget policy — resource limit check
//// 4. [actor] execute — perform the actual operation
//// 5. [actor] audit log — record the outcome
////
//// ## Usage
////
//// ```gleam
//// let state = pure.register(initial_state(), "agent_1")
//// let #(new_state, result, commands) = pure.dispatch(state, "agent_1", ReadFile("src/main.gleam"), ts)
//// ```

import gleam/dict
import gleam/set
import supernova/core/syscall/types.{
  type SyscallCommand, type SyscallOp, type SyscallState, AuditDenied,
  RecordAudit, SyscallState,
}

// ============================================================================
// Registration API
// ============================================================================

/// Register an agent to make syscalls through this gateway.
pub fn register(state: SyscallState, agent_id: String) -> SyscallState {
  SyscallState(
    ..state,
    registered_agents: set.insert(state.registered_agents, agent_id),
  )
}

/// Unregister an agent; it can no longer make syscalls.
pub fn unregister(state: SyscallState, agent_id: String) -> SyscallState {
  SyscallState(
    ..state,
    registered_agents: set.delete(state.registered_agents, agent_id),
  )
}

/// Check whether an agent is registered.
pub fn is_registered(state: SyscallState, agent_id: String) -> Bool {
  set.contains(state.registered_agents, agent_id)
}

// ============================================================================
// Authentication
// ============================================================================

/// Authenticate an agent: Ok(Nil) if registered, Error(reason) if not.
pub fn authenticate(
  state: SyscallState,
  agent_id: String,
) -> Result(Nil, String) {
  case set.contains(state.registered_agents, agent_id) {
    True -> Ok(Nil)
    False -> Error("Agent not registered: " <> agent_id)
  }
}

// ============================================================================
// Dispatch
// ============================================================================

/// Dispatch a syscall request.
///
/// Performs authentication (step 1 of the pipeline).
/// Returns:
/// - Ok(op) with empty commands if authentication passes (actor handles the rest)
/// - Error(reason) with an audit command if authentication fails
///
/// The actor executes WorkspacePolicy, BudgetPolicy, execution, and AuditLog.
pub fn dispatch(
  state: SyscallState,
  agent_id: String,
  op: SyscallOp,
  timestamp: Int,
) -> #(SyscallState, Result(SyscallOp, String), List(SyscallCommand)) {
  let new_state = increment_count(state, agent_id)
  case authenticate(state, agent_id) {
    Error(reason) -> {
      let commands = [
        RecordAudit(
          agent_id,
          types.op_to_string(op),
          types.op_target(op),
          AuditDenied,
          reason,
          timestamp,
        ),
      ]
      #(new_state, Error(reason), commands)
    }
    Ok(_) -> {
      // Authentication passed — actor handles steps 2-5
      #(new_state, Ok(op), [])
    }
  }
}

// ============================================================================
// Observability
// ============================================================================

/// Get the total syscall invocation count for an agent.
pub fn get_count(state: SyscallState, agent_id: String) -> Int {
  case dict.get(state.syscall_count, agent_id) {
    Ok(n) -> n
    Error(_) -> 0
  }
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn increment_count(state: SyscallState, agent_id: String) -> SyscallState {
  let current = case dict.get(state.syscall_count, agent_id) {
    Ok(n) -> n
    Error(_) -> 0
  }
  SyscallState(
    ..state,
    syscall_count: dict.insert(state.syscall_count, agent_id, current + 1),
  )
}
