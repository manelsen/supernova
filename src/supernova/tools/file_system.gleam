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

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import supernova/core/workspace_guard
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

/// Run a file_system tool call (`{"action","path","content"}`) on a path the
/// kernel already authorized: the gateway resolves the model's path against
/// the agent's own workspace and passes the result here. Executing the raw
/// path against the process directory let agents list the application's root
/// and read a file another agent had written (found by the harness).
pub fn execute_at(
  authorized_path: String,
  args_json: String,
) -> Result(String, String) {
  let decoder = {
    use action <- decode.field("action", decode.string)
    use content <- decode.optional_field("content", "", decode.string)
    decode.success(#(action, content))
  }
  case json.parse(from: args_json, using: decoder) {
    Error(_) -> Error("Invalid arguments for file_system")
    Ok(#(action, content)) ->
      case string.lowercase(string.trim(action)) {
        "read" -> read_at(authorized_path)
        "write" ->
          case write_at(authorized_path, content) {
            Ok(Nil) -> Ok("ok")
            Error(reason) -> Error(reason)
          }
        "list" ->
          case list_at(authorized_path) {
            Ok(entries) -> Ok(format_listing(entries))
            Error(reason) -> Error(reason)
          }
        _ -> Error("file_system action must be read, write, or list")
      }
  }
}

/// An empty directory is said in words: an empty tool result reads as "no
/// output" and the agent took it for a broken tool.
pub fn format_listing(entries: List(String)) -> String {
  case entries {
    [] -> "(empty directory)"
    _ -> string.join(entries, "\n")
  }
}

/// Read a path the kernel's workspace policy already authorized (absolute,
/// inside the caller's workspace). Only the syscall gateway calls these.
pub fn read_at(authorized_path: String) -> Result(String, String) {
  do_read_file(authorized_path)
}

/// Write a path the kernel's workspace policy already authorized.
pub fn write_at(
  authorized_path: String,
  content: String,
) -> Result(Nil, String) {
  // The parent lies inside the authorized workspace; a fresh agent's
  // workspace may not exist yet.
  case do_ensure_dir(parent_dir(authorized_path)) {
    Ok(_) -> do_write_file(authorized_path, content)
    Error(reason) -> Error(reason)
  }
}

fn parent_dir(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_, ..rest] -> rest |> list.reverse |> string.join("/")
    [] -> "."
  }
}

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn do_ensure_dir(path: String) -> Result(Nil, String)

/// List a directory the kernel's workspace policy already authorized.
pub fn list_at(authorized_path: String) -> Result(List(String), String) {
  // A fresh agent's workspace may not exist yet; listing it is listing an
  // empty directory, not an error.
  case do_ensure_dir(authorized_path) {
    Ok(_) -> do_list_dir(authorized_path)
    Error(reason) -> Error(reason)
  }
}

/// Validate that a path is within the workspace.
/// Delegates to workspace_guard for uniform path confinement
/// (blocks both path traversal and absolute paths).
fn validate_path(workspace: String, path: String) -> Result(String, String) {
  workspace_guard.validate_path(workspace, path)
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
