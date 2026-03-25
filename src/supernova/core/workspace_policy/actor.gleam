//// Workspace Policy — Actor
////
//// Singleton actor that manages workspace access control per agent.
//// Delegates pure logic to the pure module, executes side effects via FFI.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(policy) = actor.start("workspaces")
//// let assert Ok(path) = actor.authorize(policy, "agent_1", OpRead, "src/main.gleam")
//// actor.stop(policy)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import supernova/core/audit_log/actor as audit_actor
import supernova/core/audit_log/types as audit_types
import supernova/core/workspace_policy/pure
import supernova/core/workspace_policy/types.{
  type Operation, type PolicyCommand, type PolicyRule, type WorkspacePolicyState,
  WriteDeniedAudit,
}

// ============================================================================
// FFI — Timestamp (Erlang)
// ============================================================================

/// Get current timestamp in milliseconds (Erlang FFI).
@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

// ============================================================================
// Types
// ============================================================================

/// Messages that the workspace policy actor handles.
pub type PolicyMessage {
  /// Authorize an operation on a path for an agent
  Authorize(
    reply_to: Subject(Result(String, String)),
    agent_id: String,
    operation: Operation,
    path: String,
  )
  /// Set a policy rule for an agent
  SetRule(reply_to: Subject(Nil), agent_id: String, rule: PolicyRule)
  /// Get the policy rule for an agent
  GetRule(reply_to: Subject(PolicyRule), agent_id: String)
  /// Set parent agent for sub-agent inheritance
  SetParent(reply_to: Subject(Nil), agent_id: String, parent_id: String)
  /// Get the effective workspace path for an agent
  GetWorkspace(reply_to: Subject(String), agent_id: String)
  /// Allow a path prefix for an agent
  AllowPath(reply_to: Subject(Nil), agent_id: String, path_prefix: String)
  /// Deny a path prefix for an agent
  DenyPath(reply_to: Subject(Nil), agent_id: String, path_prefix: String)
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running workspace policy actor.
pub type WorkspacePolicy =
  Subject(PolicyMessage)

/// Internal actor state wrapping policy state with optional audit log.
type ActorState {
  ActorState(
    policy: WorkspacePolicyState,
    audit_log: Option(audit_actor.AuditLog),
  )
}

// ============================================================================
// Command Execution
// ============================================================================

/// Execute a list of commands returned by pure functions.
fn execute_commands(
  commands: List(PolicyCommand),
  audit_log: Option(audit_actor.AuditLog),
) -> Nil {
  list.each(commands, fn(cmd) {
    case cmd {
      WriteDeniedAudit(agent_id, operation, path, reason, timestamp) -> {
        // Log to audit log if available
        case audit_log {
          Some(log) -> {
            let entry =
              audit_types.denied_entry(
                timestamp,
                agent_id,
                "policy:" <> operation,
                path,
                reason,
              )
            audit_actor.log_entry(log, entry)
          }
          None -> Nil
        }
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
  message: PolicyMessage,
) -> actor.Next(ActorState, PolicyMessage) {
  let state = actor_state.policy
  case message {
    Authorize(reply_to, agent_id, operation, path) -> {
      let timestamp = ffi_current_timestamp()
      let #(new_state, result, commands) =
        pure.authorize(state, agent_id, operation, path, timestamp)
      execute_commands(commands, actor_state.audit_log)

      actor.send(reply_to, result)
      actor.continue(ActorState(..actor_state, policy: new_state))
    }

    SetRule(reply_to, agent_id, rule) -> {
      let new_state = pure.set_rule(state, agent_id, rule)

      actor.send(reply_to, Nil)
      actor.continue(ActorState(..actor_state, policy: new_state))
    }

    GetRule(reply_to, agent_id) -> {
      let rule = pure.get_rule(state, agent_id)
      actor.send(reply_to, rule)
      actor.continue(actor_state)
    }

    SetParent(reply_to, agent_id, parent_id) -> {
      let new_state = pure.set_parent(state, agent_id, parent_id)

      actor.send(reply_to, Nil)
      actor.continue(ActorState(..actor_state, policy: new_state))
    }

    GetWorkspace(reply_to, agent_id) -> {
      let workspace = pure.get_effective_workspace(state, agent_id)
      actor.send(reply_to, workspace)
      actor.continue(actor_state)
    }

    AllowPath(reply_to, agent_id, path_prefix) -> {
      let new_state = pure.allow_path(state, agent_id, path_prefix)

      actor.send(reply_to, Nil)
      actor.continue(ActorState(..actor_state, policy: new_state))
    }

    DenyPath(reply_to, agent_id, path_prefix) -> {
      let new_state = pure.deny_path(state, agent_id, path_prefix)

      actor.send(reply_to, Nil)
      actor.continue(ActorState(..actor_state, policy: new_state))
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

/// Start the workspace policy actor with a given workspace root.
pub fn start(
  workspace_root: String,
) -> Result(WorkspacePolicy, actor.StartError) {
  let policy_state = types.initial_state(workspace_root)
  let initial_state = ActorState(policy: policy_state, audit_log: None)

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Start the workspace policy actor with an audit log reference.
pub fn start_with_audit(
  workspace_root: String,
  audit_log: audit_actor.AuditLog,
) -> Result(WorkspacePolicy, actor.StartError) {
  let policy_state = types.initial_state(workspace_root)
  let initial_state =
    ActorState(policy: policy_state, audit_log: Some(audit_log))

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Authorize an operation on a path for an agent.
///
/// Returns Ok(full_path) if authorized, Error(message) if denied.
pub fn authorize(
  policy: WorkspacePolicy,
  agent_id: String,
  operation: Operation,
  path: String,
) -> Result(String, String) {
  actor.call(policy, waiting: 5000, sending: Authorize(
    _,
    agent_id,
    operation,
    path,
  ))
}

/// Set a policy rule for an agent.
pub fn set_rule(
  policy: WorkspacePolicy,
  agent_id: String,
  rule: PolicyRule,
) -> Nil {
  actor.call(policy, waiting: 5000, sending: SetRule(_, agent_id, rule))
}

/// Get the policy rule for an agent.
pub fn get_rule(policy: WorkspacePolicy, agent_id: String) -> PolicyRule {
  actor.call(policy, waiting: 5000, sending: GetRule(_, agent_id))
}

/// Set parent agent for sub-agent inheritance.
pub fn set_parent(
  policy: WorkspacePolicy,
  agent_id: String,
  parent_id: String,
) -> Nil {
  actor.call(policy, waiting: 5000, sending: SetParent(_, agent_id, parent_id))
}

/// Get the effective workspace path for an agent.
pub fn get_workspace(policy: WorkspacePolicy, agent_id: String) -> String {
  actor.call(policy, waiting: 5000, sending: GetWorkspace(_, agent_id))
}

/// Allow a path prefix for an agent.
pub fn allow_path(
  policy: WorkspacePolicy,
  agent_id: String,
  path_prefix: String,
) -> Nil {
  actor.call(policy, waiting: 5000, sending: AllowPath(_, agent_id, path_prefix))
}

/// Deny a path prefix for an agent.
pub fn deny_path(
  policy: WorkspacePolicy,
  agent_id: String,
  path_prefix: String,
) -> Nil {
  actor.call(policy, waiting: 5000, sending: DenyPath(_, agent_id, path_prefix))
}

/// Stop the workspace policy actor.
pub fn stop(policy: WorkspacePolicy) -> Nil {
  actor.call(policy, waiting: 5000, sending: Stop)
}
