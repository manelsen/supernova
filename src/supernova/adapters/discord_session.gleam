//// Discord Session Manager — maps Discord channels/users to sessions.
////
//// Manages the mapping between Discord channel_id + user_id and internal
//// session IDs. Creates sessions on first message, reuses on subsequent.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(mgr) = discord_session.start()
//// let assert Ok(session_id) = discord_session.get_or_create(mgr, "channel_123", "user_456")
//// ```

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/string

// ============================================================================
// Types
// ============================================================================

/// Messages for the session manager actor.
pub type SessionManagerMessage {
  /// Get or create a session for a channel+user pair
  GetOrCreate(reply_to: Subject(String), channel_id: String, user_id: String)
  /// List all active session IDs
  ListSessions(reply_to: Subject(List(String)))
  /// Remove a session
  RemoveSession(reply_to: Subject(Result(Nil, String)), session_id: String)
}

/// Manager state.
type ManagerState {
  ManagerState(
    /// Map from "channel_id:user_id" → session_id
    sessions: Dict(String, String),
  )
}

/// The manager handle.
pub type DiscordSessionManager =
  Subject(SessionManagerMessage)

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: ManagerState,
  message: SessionManagerMessage,
) -> actor.Next(ManagerState, SessionManagerMessage) {
  case message {
    GetOrCreate(reply_to, channel_id, user_id) -> {
      let key = session_key(channel_id, user_id)
      case dict.get(state.sessions, key) {
        Ok(session_id) -> {
          actor.send(reply_to, session_id)
          actor.continue(state)
        }
        Error(_) -> {
          let session_id = "discord:" <> channel_id <> ":" <> user_id
          let new_sessions = dict.insert(state.sessions, key, session_id)
          actor.send(reply_to, session_id)
          actor.continue(ManagerState(sessions: new_sessions))
        }
      }
    }

    ListSessions(reply_to) -> {
      let sessions =
        state.sessions
        |> dict.values
        |> list.sort(string.compare)
      actor.send(reply_to, sessions)
      actor.continue(state)
    }

    RemoveSession(reply_to, session_id) -> {
      // Find and remove by value
      let new_sessions =
        state.sessions
        |> dict.filter(fn(_k, v) { v != session_id })
      case dict.size(new_sessions) < dict.size(state.sessions) {
        True -> {
          actor.send(reply_to, Ok(Nil))
          actor.continue(ManagerState(sessions: new_sessions))
        }
        False -> {
          actor.send(reply_to, Error("Session not found: " <> session_id))
          actor.continue(state)
        }
      }
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Create a session key from channel and user IDs.
pub fn session_key(channel_id: String, user_id: String) -> String {
  channel_id <> ":" <> user_id
}

/// Start a new Discord session manager.
pub fn start() -> Result(DiscordSessionManager, actor.StartError) {
  let initial_state = ManagerState(sessions: dict.new())

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(reason) -> Error(reason)
  }
}

/// Get or create a session for a channel+user pair.
///
/// Returns the session ID (format: "discord:channel_id:user_id").
/// If a session already exists for this pair, returns the existing ID.
pub fn get_or_create(
  manager: DiscordSessionManager,
  channel_id: String,
  user_id: String,
) -> Result(String, Nil) {
  let session_id =
    actor.call(manager, waiting: 5000, sending: GetOrCreate(
      _,
      channel_id,
      user_id,
    ))
  Ok(session_id)
}

/// List all active session IDs.
pub fn list_sessions(manager: DiscordSessionManager) -> List(String) {
  actor.call(manager, waiting: 5000, sending: ListSessions)
}

/// Remove a session by ID.
pub fn remove_session(
  manager: DiscordSessionManager,
  session_id: String,
) -> Result(Nil, String) {
  actor.call(manager, waiting: 5000, sending: RemoveSession(_, session_id))
}
