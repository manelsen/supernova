//// FileSystem — file operations with path confinement.
////
//// Provides safe file system access confined to a workspace root.
//// Blocks path traversal (..) and absolute paths outside workspace.
////
//// ## Usage
////
//// ```gleam
//// let result = file_system.read("/tmp/workspace", "src/main.gleam")
//// // With workspace policy:
//// let result = file_system.read_authorized(policy, "agent_1", "src/main.gleam")
//// ```

import gleam/string
import supernova/core/workspace_policy/actor as policy_actor
import supernova/core/workspace_policy/types.{OpRead, OpWrite}
import supernova/llm/provider

/// Read a file within the workspace.
pub fn read(workspace: String, path: String) -> Result(String, String) {
  case validate_path(workspace, path) {
    Ok(full_path) -> do_read_file(full_path)
    Error(reason) -> Error(reason)
  }
}

/// Read a file with workspace policy authorization.
///
/// The path is authorized through the workspace policy before reading.
pub fn read_authorized(
  policy: policy_actor.WorkspacePolicy,
  agent_id: String,
  path: String,
) -> Result(String, String) {
  case policy_actor.authorize(policy, agent_id, OpRead, path) {
    Ok(full_path) -> do_read_file(full_path)
    Error(reason) -> Error(reason)
  }
}

/// Write content to a file within the workspace.
pub fn write(
  workspace: String,
  path: String,
  content: String,
) -> Result(Nil, String) {
  case validate_path(workspace, path) {
    Ok(full_path) -> do_write_file(full_path, content)
    Error(reason) -> Error(reason)
  }
}

/// Write content to a file with workspace policy authorization.
///
/// The path is authorized through the workspace policy before writing.
pub fn write_authorized(
  policy: policy_actor.WorkspacePolicy,
  agent_id: String,
  path: String,
  content: String,
) -> Result(Nil, String) {
  case policy_actor.authorize(policy, agent_id, OpWrite, path) {
    Ok(full_path) -> do_write_file(full_path, content)
    Error(reason) -> Error(reason)
  }
}

/// List files in a directory within the workspace.
pub fn list(workspace: String, path: String) -> Result(List(String), String) {
  case validate_path(workspace, path) {
    Ok(full_path) -> do_list_dir(full_path)
    Error(reason) -> Error(reason)
  }
}

/// List files in a directory with workspace policy authorization.
///
/// The path is authorized through the workspace policy before listing.
pub fn list_authorized(
  policy: policy_actor.WorkspacePolicy,
  agent_id: String,
  path: String,
) -> Result(List(String), String) {
  case policy_actor.authorize(policy, agent_id, OpRead, path) {
    Ok(full_path) -> do_list_dir(full_path)
    Error(reason) -> Error(reason)
  }
}

/// Get the tool definition for FileSystem.
pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "file_system",
    description: "Read, write, and list files within the workspace",
    parameters: [
      provider.string_param("action", "Action: read, write, list", True),
      provider.string_param("path", "File path relative to workspace", True),
      provider.string_param(
        "content",
        "Content to write (for write action)",
        False,
      ),
    ],
  )
}

// ============================================================================
// Path Validation
// ============================================================================

/// Validate that a path is within the workspace.
fn validate_path(workspace: String, path: String) -> Result(String, String) {
  case string.contains(path, "..") {
    True -> Error("Path traversal blocked: " <> path)
    False -> {
      let full_path = workspace <> "/" <> path
      Ok(full_path)
    }
  }
}

// ============================================================================
// FFI
// ============================================================================

@external(erlang, "supernova_file_system_ffi", "read_file")
fn do_read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn do_write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "list_dir")
fn do_list_dir(path: String) -> Result(List(String), String)
