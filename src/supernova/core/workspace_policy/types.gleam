//// Workspace Policy — Pure Types
////
//// Pure data structures for access control per workspace.
//// No FFI, no side effects.
//// These types define the domain model for workspace-level authorization.

import gleam/dict.{type Dict}

// ============================================================================
// Types
// ============================================================================

/// Operations that can be authorized on a workspace.
pub type Operation {
  /// Read a file or directory
  OpRead
  /// Write a file
  OpWrite
  /// Execute a shell command
  OpShell
}

/// A policy rule for a specific agent.
pub type PolicyRule {
  PolicyRule(
    /// The agent this rule applies to
    agent_id: String,
    /// List of allowed path prefixes (empty = use default workspace)
    allowed_paths: List(String),
    /// List of denied path prefixes (takes precedence over allowed)
    denied_paths: List(String),
    /// Whether the agent can read paths outside its workspace
    external_read_allowed: Bool,
  )
}

/// Result of an authorization check.
pub type PolicyError {
  /// Access denied with reason
  AccessDenied(
    agent_id: String,
    operation: String,
    path: String,
    reason: String,
  )
}

/// Command pattern for I/O operations.
/// Pure functions return commands; the actor executes them.
pub type PolicyCommand {
  /// Write audit log for denied access attempt
  WriteDeniedAudit(
    agent_id: String,
    operation: String,
    path: String,
    reason: String,
    timestamp: Int,
  )
}

/// The workspace policy state maintained by the actor.
pub type WorkspacePolicyState {
  WorkspacePolicyState(
    /// Per-agent policy rules
    rules: Dict(String, PolicyRule),
    /// Default workspace root path (e.g., "workspaces")
    workspace_root: String,
    /// Parent-child relationships for sub-agent inheritance
    parent_of: Dict(String, String),
  )
}

// ============================================================================
// Default Values
// ============================================================================

/// Create a default policy rule for an agent.
/// Default: agent can only access workspaces/<agent_id>/
pub fn default_rule(agent_id: String) -> PolicyRule {
  PolicyRule(
    agent_id: agent_id,
    allowed_paths: [],
    denied_paths: [],
    external_read_allowed: False,
  )
}

/// Create a policy rule with external read access.
pub fn rule_with_external_read(agent_id: String) -> PolicyRule {
  PolicyRule(
    agent_id: agent_id,
    allowed_paths: [],
    denied_paths: [],
    external_read_allowed: True,
  )
}

/// Create an initial empty workspace policy state.
pub fn initial_state(workspace_root: String) -> WorkspacePolicyState {
  WorkspacePolicyState(
    rules: dict.new(),
    workspace_root: workspace_root,
    parent_of: dict.new(),
  )
}
