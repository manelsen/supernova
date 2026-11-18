//// Workspace Policy — Pure Functions
////
//// Pure functions for workspace access control. No FFI, no side effects.
//// Functions take state and return new state + commands for the actor to execute.
////
//// ## Usage
////
//// ```gleam
//// let #(new_state, result, commands) = pure.authorize(state, "agent_1", OpRead, "src/main.gleam", timestamp)
//// ```

import gleam/dict
import gleam/list
import gleam/string
import supernova/core/workspace_policy/types.{
  type Operation, type PolicyCommand, type PolicyRule, type WorkspacePolicyState,
  OpRead, OpShell, OpWrite, PolicyRule, WorkspacePolicyState, WriteDeniedAudit,
}

// ============================================================================
// Public API
// ============================================================================

/// Authorize an operation on a path for an agent.
///
/// Returns Ok(full_path) if authorized, Error(message) if denied.
/// Also returns commands for the actor to execute (audit logging).
pub fn authorize(
  state: WorkspacePolicyState,
  agent_id: String,
  operation: Operation,
  path: String,
  timestamp: Int,
) -> #(WorkspacePolicyState, Result(String, String), List(PolicyCommand)) {
  // Block path traversal first
  case contains_traversal(path) {
    True -> {
      let reason = "Path traversal blocked: " <> path
      let commands = [
        WriteDeniedAudit(
          agent_id,
          op_to_string(operation),
          path,
          reason,
          timestamp,
        ),
      ]
      #(state, Error(reason), commands)
    }
    False -> {
      // Check if path is absolute
      case string.starts_with(path, "/") {
        True -> authorize_absolute(state, agent_id, operation, path, timestamp)
        False -> authorize_relative(state, agent_id, operation, path, timestamp)
      }
    }
  }
}

/// Set a policy rule for an agent.
pub fn set_rule(
  state: WorkspacePolicyState,
  agent_id: String,
  rule: PolicyRule,
) -> WorkspacePolicyState {
  WorkspacePolicyState(..state, rules: dict.insert(state.rules, agent_id, rule))
}

/// Get the policy rule for an agent.
/// Returns the agent's rule, or a default rule if not set.
pub fn get_rule(state: WorkspacePolicyState, agent_id: String) -> PolicyRule {
  case dict.get(state.rules, agent_id) {
    Ok(rule) -> rule
    Error(_) -> types.default_rule(agent_id)
  }
}

/// Set parent agent for sub-agent inheritance.
/// Sub-agents inherit the parent's workspace instead of creating their own.
pub fn set_parent(
  state: WorkspacePolicyState,
  agent_id: String,
  parent_id: String,
) -> WorkspacePolicyState {
  WorkspacePolicyState(
    ..state,
    parent_of: dict.insert(state.parent_of, agent_id, parent_id),
  )
}

/// Get the effective workspace path for an agent.
/// Resolves inheritance chain: if agent has a parent, uses parent's workspace.
pub fn get_effective_workspace(
  state: WorkspacePolicyState,
  agent_id: String,
) -> String {
  case dict.get(state.parent_of, agent_id) {
    Ok(parent_id) -> get_effective_workspace(state, parent_id)
    Error(_) -> state.workspace_root <> "/" <> agent_id
  }
}

/// Check if an agent has external read access.
pub fn has_external_read(
  state: WorkspacePolicyState,
  agent_id: String,
) -> Bool {
  let rule = get_rule(state, agent_id)
  rule.external_read_allowed
}

/// Add an allowed path prefix for an agent.
pub fn allow_path(
  state: WorkspacePolicyState,
  agent_id: String,
  path_prefix: String,
) -> WorkspacePolicyState {
  let rule = get_rule(state, agent_id)
  let new_rule =
    PolicyRule(..rule, allowed_paths: [path_prefix, ..rule.allowed_paths])
  WorkspacePolicyState(
    ..state,
    rules: dict.insert(state.rules, agent_id, new_rule),
  )
}

/// Add a denied path prefix for an agent.
pub fn deny_path(
  state: WorkspacePolicyState,
  agent_id: String,
  path_prefix: String,
) -> WorkspacePolicyState {
  let rule = get_rule(state, agent_id)
  let new_rule =
    PolicyRule(..rule, denied_paths: [path_prefix, ..rule.denied_paths])
  WorkspacePolicyState(
    ..state,
    rules: dict.insert(state.rules, agent_id, new_rule),
  )
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Check if a path contains traversal patterns.
fn contains_traversal(path: String) -> Bool {
  string.contains(path, "..")
}

/// Convert operation to string for logging.
fn op_to_string(operation: Operation) -> String {
  case operation {
    OpRead -> "read"
    OpWrite -> "write"
    OpShell -> "shell"
  }
}

/// Authorize an absolute path.
fn authorize_absolute(
  state: WorkspacePolicyState,
  agent_id: String,
  operation: Operation,
  path: String,
  timestamp: Int,
) -> #(WorkspacePolicyState, Result(String, String), List(PolicyCommand)) {
  let workspace = get_effective_workspace(state, agent_id)
  let rule = get_rule(state, agent_id)

  // Check if absolute path is within the agent's workspace
  case string.starts_with(path, workspace <> "/") || path == workspace {
    True -> {
      // Path is within workspace, check denied paths
      case is_path_denied(rule, path) {
        True -> {
          let reason = "Path denied by policy: " <> path
          let commands = [
            WriteDeniedAudit(
              agent_id,
              op_to_string(operation),
              path,
              reason,
              timestamp,
            ),
          ]
          #(state, Error(reason), commands)
        }
        False -> #(state, Ok(path), [])
      }
    }
    False -> {
      // Path is outside workspace
      case operation {
        OpRead -> {
          case rule.external_read_allowed {
            True -> #(state, Ok(path), [])
            False -> {
              let reason = "External read not allowed for agent: " <> agent_id
              let commands = [
                WriteDeniedAudit(
                  agent_id,
                  op_to_string(operation),
                  path,
                  reason,
                  timestamp,
                ),
              ]
              #(state, Error(reason), commands)
            }
          }
        }
        OpWrite | OpShell -> {
          let reason =
            "Absolute path outside workspace requires external access: " <> path
          let commands = [
            WriteDeniedAudit(
              agent_id,
              op_to_string(operation),
              path,
              reason,
              timestamp,
            ),
          ]
          #(state, Error(reason), commands)
        }
      }
    }
  }
}

/// Authorize a relative path.
fn authorize_relative(
  state: WorkspacePolicyState,
  agent_id: String,
  operation: Operation,
  path: String,
  timestamp: Int,
) -> #(WorkspacePolicyState, Result(String, String), List(PolicyCommand)) {
  let workspace = get_effective_workspace(state, agent_id)
  let rule = get_rule(state, agent_id)
  let full_path = workspace <> "/" <> path

  // Check denied paths first (takes precedence)
  case is_path_denied(rule, full_path) {
    True -> {
      let reason = "Path denied by policy: " <> path
      let commands = [
        WriteDeniedAudit(
          agent_id,
          op_to_string(operation),
          path,
          reason,
          timestamp,
        ),
      ]
      #(state, Error(reason), commands)
    }
    False -> {
      // Check if there are explicit allowed paths
      case list.is_empty(rule.allowed_paths) {
        True -> {
          // No explicit allowed paths — default: allow within workspace
          #(state, Ok(full_path), [])
        }
        False -> {
          // Has explicit allowed paths — check if path matches
          case is_path_allowed(rule, full_path) {
            True -> #(state, Ok(full_path), [])
            False -> {
              let reason = "Path not in allowed list: " <> path
              let commands = [
                WriteDeniedAudit(
                  agent_id,
                  op_to_string(operation),
                  path,
                  reason,
                  timestamp,
                ),
              ]
              #(state, Error(reason), commands)
            }
          }
        }
      }
    }
  }
}

/// Check if a path matches any denied prefix.
fn is_path_denied(rule: PolicyRule, path: String) -> Bool {
  list.any(rule.denied_paths, fn(prefix) { string.starts_with(path, prefix) })
}

/// Check if a path matches any allowed prefix.
fn is_path_allowed(rule: PolicyRule, path: String) -> Bool {
  list.any(rule.allowed_paths, fn(prefix) { string.starts_with(path, prefix) })
}
