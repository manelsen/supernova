//// Session Server — manages state for a single session.
////
//// Each session holds conversation history, status, and configuration.
//// The session server is an actor that processes messages asynchronously.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(session) = server.new("user_123")
//// let status = server.get_status(session)
//// let assert Ok(Nil) = server.set_model(session, "gpt-4")
//// let assert Ok(Nil) = server.stop(session)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

// ============================================================================
// Types
// ============================================================================

/// Session status.
pub type SessionStatus {
  /// Session is idle, waiting for input
  Idle
  /// Session is processing input
  Processing
  /// Session has encountered an error
  Error(reason: String)
}

/// A chat message in the session history.
pub type ChatMessage {
  ChatMessage(role: String, content: String)
}

/// Messages that the session server handles.
pub type SessionMessage {
  /// Get the session ID
  GetSessionId(reply_to: Subject(String))
  /// Get the current session status
  GetStatus(reply_to: Subject(SessionStatus))
  /// Get the conversation history
  GetHistory(reply_to: Subject(List(ChatMessage)))
  /// Get the model override (if any)
  GetModel(reply_to: Subject(Option(String)))
  /// Set the model override
  SetModel(reply_to: Subject(Result(Nil, Nil)), model: String)
  /// Clear the model override
  ClearModel(reply_to: Subject(Result(Nil, Nil)))
  /// Stop the session
  Stop(reply_to: Subject(Result(Nil, Nil)))
}

/// The session handle (subject to send messages to).
pub type Session =
  Subject(SessionMessage)

/// Internal session state.
type SessionState {
  SessionState(
    session_id: String,
    status: SessionStatus,
    history: List(ChatMessage),
    model_override: Option(String),
  )
}

// ============================================================================
// Actor Handler
// ============================================================================

/// Handle session messages.
fn handle_session_message(
  state: SessionState,
  message: SessionMessage,
) -> actor.Next(SessionState, SessionMessage) {
  case message {
    GetSessionId(reply_to) -> {
      actor.send(reply_to, state.session_id)
      actor.continue(state)
    }

    GetStatus(reply_to) -> {
      actor.send(reply_to, state.status)
      actor.continue(state)
    }

    GetHistory(reply_to) -> {
      actor.send(reply_to, state.history)
      actor.continue(state)
    }

    GetModel(reply_to) -> {
      actor.send(reply_to, state.model_override)
      actor.continue(state)
    }

    SetModel(reply_to, model) -> {
      let new_state = SessionState(..state, model_override: Some(model))
      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    ClearModel(reply_to) -> {
      let new_state = SessionState(..state, model_override: None)
      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Ok(Nil))
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Create a new session with the given ID.
///
/// Returns the session actor subject on success.
pub fn new(session_id: String) -> Result(Session, actor.StartError) {
  let initial_state =
    SessionState(
      session_id: session_id,
      status: Idle,
      history: [],
      model_override: None,
    )

  actor.new(initial_state)
  |> actor.on_message(handle_session_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// Get the session ID.
pub fn get_session_id(session: Session) -> String {
  actor.call(session, waiting: 5000, sending: GetSessionId)
}

/// Get the current session status.
pub fn get_status(session: Session) -> SessionStatus {
  actor.call(session, waiting: 5000, sending: GetStatus)
}

/// Get the conversation history.
pub fn get_history(session: Session) -> List(ChatMessage) {
  actor.call(session, waiting: 5000, sending: GetHistory)
}

/// Get the model override (if any).
pub fn get_model(session: Session) -> Option(String) {
  actor.call(session, waiting: 5000, sending: GetModel)
}

/// Set the model override.
pub fn set_model(session: Session, model: String) -> Result(Nil, Nil) {
  actor.call(session, waiting: 5000, sending: SetModel(_, model))
}

/// Clear the model override.
pub fn clear_model(session: Session) -> Result(Nil, Nil) {
  actor.call(session, waiting: 5000, sending: ClearModel)
}

/// Stop the session.
pub fn stop(session: Session) -> Result(Nil, Nil) {
  actor.call(session, waiting: 5000, sending: Stop)
}
