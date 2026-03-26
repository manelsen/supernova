//// Session Management — unified session resolution for all channel adapters.
////
//// This module provides a common interface for session resolution across
//// all channel adapters, eliminating code duplication and providing a
//// consistent session management pattern.
////
//// ## Usage
////
//// ```gleam
//// // With session manager (Telegram, Discord)
//// let resolver = session.with_manager(
////   fn(channel_id, user_id) {
////     telegram_session.get_or_create(session_mgr, channel_id)
////   }
//// )
////
//// // Without session manager (Matrix, Slack, etc.)
//// let resolver = session.without_manager("matrix")
////
//// // Use with channel_common_router
//// let #(_, result) = channel_common_router.handle_inbound(
////   "telegram", inbound, config, state, resolver
//// )
//// ```

import gleam/string

/// Contrato para resolução de sessões por canal.
///
/// Each channel adapter uses a SessionResolver to resolve or create
/// a session ID from channel-specific identifiers.
pub type SessionResolver {
  SessionResolver(
    /// Resolve or create session ID from channel and user identifiers
    resolve: fn(String, String) -> String
  )
}

/// Create a SessionResolver with a session manager (Telegram, Discord).
///
/// The manager_fn is called to resolve sessions. If it fails, a fallback
/// session ID is generated.
pub fn with_manager(
  manager_fn: fn(String, String) -> String
) -> SessionResolver {
  SessionResolver(
    resolve: fn(channel_id, user_id) {
      let session_id = manager_fn(channel_id, user_id)
      case string.is_empty(session_id) {
        True -> fallback_session_id(channel_id, user_id)
        False -> session_id
      }
    }
  )
}

/// Create a SessionResolver without a session manager (generic channels).
///
/// This is used for channels that don't have a dedicated session manager
/// (Matrix, Slack, Lark, etc.). The session ID is a simple concatenation
/// of the channel prefix and identifiers.
pub fn without_manager(channel_prefix: String) -> SessionResolver {
  SessionResolver(
    resolve: fn(channel_id, user_id) {
      channel_prefix <> ":" <> channel_id <> ":" <> user_id
    }
  )
}

/// Generate a fallback session ID when session manager fails.
fn fallback_session_id(channel_id: String, user_id: String) -> String {
  "session:" <> channel_id <> ":" <> user_id
}
