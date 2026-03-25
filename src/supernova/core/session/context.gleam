//// Session Context — bindings and workspace for a session.
////
//// Each session has a context that holds key-value bindings and a workspace path.
//// Context is a pure data structure (no actor needed).
////
//// ## Usage
////
//// ```gleam
//// let ctx = context.new("user_123")
//// let ctx = context.set_binding(ctx, "model", "gpt-4")
//// let assert Some("gpt-4") = context.get_binding(ctx, "model")
//// ```

import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}

// ============================================================================
// Types
// ============================================================================

/// Session context holding bindings and workspace configuration.
pub type SessionContext {
  SessionContext(
    /// Unique session identifier
    session_id: String,
    /// Key-value bindings for session state
    bindings: Dict(String, String),
    /// Workspace root path for file operations
    workspace_path: String,
  )
}

// ============================================================================
// Public API
// ============================================================================

/// Create a new session context with the given ID.
///
/// Initializes with empty bindings and a default workspace path
/// based on the session ID.
pub fn new(session_id: String) -> SessionContext {
  SessionContext(
    session_id: session_id,
    bindings: dict.new(),
    workspace_path: "/tmp/supernova/" <> session_id,
  )
}

/// Get a binding value by key.
///
/// Returns Some(value) if the key exists, None otherwise.
pub fn get_binding(ctx: SessionContext, key: String) -> Option(String) {
  case dict.get(ctx.bindings, key) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

/// Set a binding key-value pair.
///
/// Returns a new context with the binding added or updated.
pub fn set_binding(
  ctx: SessionContext,
  key: String,
  value: String,
) -> SessionContext {
  let new_bindings = dict.insert(ctx.bindings, key, value)
  SessionContext(..ctx, bindings: new_bindings)
}

/// Set the workspace path for this session.
///
/// Returns a new context with the updated workspace path.
pub fn set_workspace_path(ctx: SessionContext, path: String) -> SessionContext {
  SessionContext(..ctx, workspace_path: path)
}
