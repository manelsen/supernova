//// Telegram Session Manager — maps Telegram chats to sessions.
////
//// Manages the mapping between Telegram chat_id and internal session IDs.
//// Simpler than Discord (no user_id needed — Telegram chats are 1:1 or groups).

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/string

// ============================================================================
// Types
// ============================================================================

pub type TelegramSessionMessage {
  GetOrCreate(reply_to: Subject(String), chat_id: String)
  ListSessions(reply_to: Subject(List(String)))
  RemoveSession(reply_to: Subject(Result(Nil, String)), session_id: String)
}

type TelegramSessionState {
  TelegramSessionState(sessions: Dict(String, String))
}

pub type TelegramSessionManager =
  Subject(TelegramSessionMessage)

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: TelegramSessionState,
  message: TelegramSessionMessage,
) -> actor.Next(TelegramSessionState, TelegramSessionMessage) {
  case message {
    GetOrCreate(reply_to, chat_id) -> {
      case dict.get(state.sessions, chat_id) {
        Ok(session_id) -> {
          actor.send(reply_to, session_id)
          actor.continue(state)
        }
        Error(_) -> {
          let session_id = "telegram:" <> chat_id
          let new_sessions = dict.insert(state.sessions, chat_id, session_id)
          actor.send(reply_to, session_id)
          actor.continue(TelegramSessionState(sessions: new_sessions))
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
      let new_sessions =
        state.sessions
        |> dict.filter(fn(_k, v) { v != session_id })
      case dict.size(new_sessions) < dict.size(state.sessions) {
        True -> {
          actor.send(reply_to, Ok(Nil))
          actor.continue(TelegramSessionState(sessions: new_sessions))
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

/// Builds the canonical session key for a Telegram chat.
pub fn session_key(chat_id: String) -> String {
  "telegram:" <> chat_id
}

/// Starts the Telegram session manager actor.
pub fn start() -> Result(TelegramSessionManager, actor.StartError) {
  let initial_state = TelegramSessionState(sessions: dict.new())

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(reason) -> Error(reason)
  }
}

/// Gets an existing session for a chat or creates one atomically.
pub fn get_or_create(
  manager: TelegramSessionManager,
  chat_id: String,
) -> Result(String, Nil) {
  let session_id =
    actor.call(manager, waiting: 5000, sending: GetOrCreate(_, chat_id))
  Ok(session_id)
}

/// Lists all tracked Telegram session IDs.
pub fn list_sessions(manager: TelegramSessionManager) -> List(String) {
  actor.call(manager, waiting: 5000, sending: ListSessions)
}

/// Removes a session by ID from the manager state.
pub fn remove_session(
  manager: TelegramSessionManager,
  session_id: String,
) -> Result(Nil, String) {
  actor.call(manager, waiting: 5000, sending: RemoveSession(_, session_id))
}
