//// Capability Manifest — Pure Types
////
//// Pure data structures for per-agent tool allowlist/denylist.
//// No FFI, no side effects.
//// These types define the domain model for tool capability enforcement.

import gleam/dict.{type Dict}

// ============================================================================
// Types
// ============================================================================

/// A capability manifest defining which tools an agent can use.
pub type CapabilityManifest {
  CapabilityManifest(
    /// List of tool names this agent is allowed to use
    allowed_tools: List(String),
    /// List of tool names this agent is denied from using
    denied_tools: List(String),
  )
}

/// Error type for capability violations.
pub type CapabilityError {
  /// Tool access denied for agent
  CapabilityDenied(agent_id: String, tool_name: String, reason: String)
}

/// Command pattern for I/O operations.
/// Pure functions return commands; the actor executes them.
pub type CapabilityCommand {
  /// Write audit log for denied capability access
  WriteCapabilityAudit(
    agent_id: String,
    tool_name: String,
    reason: String,
    timestamp: Int,
  )
  /// Load manifest from YAML file
  LoadManifestFile(agent_id: String, path: String)
}

/// The capability manifest state maintained by the actor.
pub type CapabilityManifestState {
  CapabilityManifestState(
    /// Per-agent capability manifests
    manifests: Dict(String, CapabilityManifest),
    /// Workspace root path for YAML file loading
    workspace_root: String,
  )
}

// ============================================================================
// Default Values
// ============================================================================

/// Create a default capability manifest.
/// Default: basic tools (filesystem, web) allowed; dangerous tools (shell, github) denied.
pub fn default_manifest() -> CapabilityManifest {
  CapabilityManifest(
    allowed_tools: [
      "filesystem",
      "web",
      "read_file",
      "write_file",
      "list_directory",
    ],
    denied_tools: [
      "shell",
      "execute_command",
      "github",
      "git_push",
      "git_commit",
    ],
  )
}

/// Create an initial empty capability manifest state.
pub fn initial_state(workspace_root: String) -> CapabilityManifestState {
  CapabilityManifestState(manifests: dict.new(), workspace_root: workspace_root)
}
