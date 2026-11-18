//// Access Control — Pure Types
////
//// Domain model for the closed-group access policy: who may talk to the
//// instance (allowlist with `Admin`/`Member` roles) and which group chats or
//// servers are authorized. No FFI, no side effects.

import gleam/dict.{type Dict}

// ============================================================================
// Policy
// ============================================================================

/// How the instance decides who may use it.
pub type Mode {
  /// Only principals explicitly listed as admins or members may use the bot.
  Allowlist
  /// Anyone may use the bot (still subject to budgets and capabilities).
  Open
}

/// Role granted to an authorized principal.
pub type Role {
  Admin
  Member
}

/// Closed-group access configuration.
pub type AccessConfig {
  AccessConfig(
    /// Allowlist (default) or open.
    mode: Mode,
    /// Admin principals in `<channel>:<user_id>` form.
    admins: List(String),
    /// Member principals in `<channel>:<user_id>` form.
    members: List(String),
    /// Reply sent at most once per day to denied principals.
    denied_reply: String,
    /// Authorized group chats / guilds in `<channel>:<id>` form.
    /// Private conversations with authorized principals are always allowed.
    allowed_chats: List(String),
  )
}

// ============================================================================
// Decisions
// ============================================================================

/// Whether a principal may use the instance, and with which role.
pub type Decision {
  Allowed(role: Role)
  Denied
}

/// Whether a conversation (private chat, group, or server channel) is allowed.
pub type ChatDecision {
  ChatAllowed
  ChatDenied
}

// ============================================================================
// Commands
// ============================================================================

/// A parsed `/acesso` admin command.
pub type Command {
  ListAccess
  AddAccess(principal_id: String, role: Role)
  RemoveAccess(principal_id: String)
  AddChat(chat_id: String)
  RemoveChat(chat_id: String)
  ListChats
}

// ============================================================================
// Persistence
// ============================================================================

/// Runtime state persisted to `<data_dir>/access.json`.
///
/// Configuration-only fields (`mode`, `denied_reply`) stay with the caller;
/// only the mutable lists and the anti-spam notice timestamps are stored.
pub type PersistedState {
  PersistedState(
    admins: List(String),
    members: List(String),
    allowed_chats: List(String),
    denied_notices: Dict(String, Int),
    chat_denied_notices: Dict(String, Int),
  )
}

// ============================================================================
// Defaults
// ============================================================================

/// Deny-by-default policy: allowlist with empty lists.
pub fn default_config() -> AccessConfig {
  AccessConfig(
    mode: Allowlist,
    admins: [],
    members: [],
    denied_reply: "Esta instância é privada.",
    allowed_chats: [],
  )
}
