//// Workspace Guard — path confinement for file operations.
////
//// Validates that file paths don't escape the workspace root.
//// Blocks path traversal (..) and absolute paths outside workspace.
////
//// ## Usage
////
//// ```gleam
//// workspace_guard.validate_path("/home/user/project", "src/main.gleam")
//// // -> Ok("/home/user/project/src/main.gleam")
////
//// workspace_guard.validate_path("/home/user/project", "../etc/passwd")
//// // -> Error("Path traversal blocked")
//// ```

import gleam/string

/// Validate that a path is within the workspace.
///
/// Returns the full path on success, or an error message on failure.
pub fn validate_path(workspace: String, path: String) -> Result(String, String) {
  // Block absolute paths
  case string.starts_with(path, "/") {
    True -> Error("Absolute path blocked: " <> path)
    False -> {
      // Block path traversal
      case string.contains(path, "..") {
        True -> Error("Path traversal blocked: " <> path)
        False -> {
          let full_path = workspace <> "/" <> path
          Ok(full_path)
        }
      }
    }
  }
}
