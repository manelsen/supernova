//// Session Supervisor — manages lifecycle of session actors.
////
//// Provides a centralized entry point for creating and terminating sessions.
//// Each session runs as an independent actor, allowing for fault isolation.
////
//// ## Architecture
////
////     Supervisor (actor)
////       ├── session_001 → Session actor
////       ├── session_002 → Session actor
////       └── session_N  → Session actor
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(sup) = supervisor.start()
//// let assert Ok(_) = supervisor.start_session(sup, "user_123")
//// let sessions = supervisor.list_sessions(sup)
//// let assert Ok(Nil) = supervisor.stop_session(sup, "user_123")
//// ```

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/order
import gleam/otp/actor
import gleam/result
import gleam/string

// ============================================================================
// Types
// ============================================================================

/// Messages that a session actor handles.
pub type SessionMessage {
  /// Get the session ID
  GetSessionId(reply_to: Subject(String))
  /// Stop the session
  StopSession
}

/// Messages for the supervisor actor.
pub type SupervisorMessage {
  /// Start a new session with the given ID
  StartSession(
    reply_to: Subject(Result(Subject(SessionMessage), SupervisorError)),
    session_id: String,
  )
  /// Stop a session by ID
  StopSessionById(
    reply_to: Subject(Result(Nil, SupervisorError)),
    session_id: String,
  )
  /// List all active session IDs
  ListSessions(reply_to: Subject(List(String)))
  /// Get a session subject by ID
  GetSession(
    reply_to: Subject(Result(Subject(SessionMessage), SupervisorError)),
    session_id: String,
  )
  /// Stop the supervisor
  StopSupervisor(reply_to: Subject(Nil))
}

/// Errors that can occur in the supervisor.
pub type SupervisorError {
  /// A session with this ID already exists
  SessionAlreadyExists(session_id: String)
  /// No session found with this ID
  SessionNotFound(session_id: String)
  /// Failed to start a session actor
  SessionStartError(reason: String)
}

/// The supervisor handle (subject to send messages to).
pub type SessionSupervisor =
  Subject(SupervisorMessage)

/// Internal supervisor state.
type SupervisorState {
  SupervisorState(sessions: Dict(String, Subject(SessionMessage)))
}

// ============================================================================
// Session Actor (minimal — will be replaced by full Session Server in 1.2)
// ============================================================================

/// Handle messages for a minimal session actor.
fn handle_session_message(
  state: String,
  message: SessionMessage,
) -> actor.Next(String, SessionMessage) {
  case message {
    GetSessionId(reply_to) -> {
      actor.send(reply_to, state)
      actor.continue(state)
    }
    StopSession -> {
      actor.stop()
    }
  }
}

/// Start a minimal session actor with the given ID.
fn start_session_actor(
  session_id: String,
) -> Result(Subject(SessionMessage), actor.StartError) {
  actor.new(session_id)
  |> actor.on_message(handle_session_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

// ============================================================================
// Supervisor Actor
// ============================================================================

/// Handle supervisor messages.
fn handle_supervisor_message(
  state: SupervisorState,
  message: SupervisorMessage,
) -> actor.Next(SupervisorState, SupervisorMessage) {
  case message {
    StartSession(reply_to, session_id) -> {
      case dict.get(state.sessions, session_id) {
        Ok(_) -> {
          actor.send(
            reply_to,
            Error(SessionAlreadyExists(session_id: session_id)),
          )
          actor.continue(state)
        }
        Error(_) -> {
          case start_session_actor(session_id) {
            Ok(subject) -> {
              let new_sessions =
                dict.insert(state.sessions, session_id, subject)
              let new_state = SupervisorState(sessions: new_sessions)
              actor.send(reply_to, Ok(subject))
              actor.continue(new_state)
            }
            Error(_reason) -> {
              actor.send(
                reply_to,
                Error(SessionStartError(reason: "Failed to start session actor")),
              )
              actor.continue(state)
            }
          }
        }
      }
    }

    StopSessionById(reply_to, session_id) -> {
      case dict.get(state.sessions, session_id) {
        Ok(subject) -> {
          actor.send(subject, StopSession)
          let new_sessions = dict.delete(state.sessions, session_id)
          let new_state = SupervisorState(sessions: new_sessions)
          actor.send(reply_to, Ok(Nil))
          actor.continue(new_state)
        }
        Error(_) -> {
          actor.send(reply_to, Error(SessionNotFound(session_id: session_id)))
          actor.continue(state)
        }
      }
    }

    ListSessions(reply_to) -> {
      let ids =
        state.sessions
        |> dict.keys
        |> list.sort(string_compare)
      actor.send(reply_to, ids)
      actor.continue(state)
    }

    GetSession(reply_to, session_id) -> {
      case dict.get(state.sessions, session_id) {
        Ok(subject) -> {
          actor.send(reply_to, Ok(subject))
          actor.continue(state)
        }
        Error(_) -> {
          actor.send(reply_to, Error(SessionNotFound(session_id: session_id)))
          actor.continue(state)
        }
      }
    }

    StopSupervisor(reply_to) -> {
      // Stop all sessions
      state.sessions
      |> dict.values
      |> list.each(fn(subject) { actor.send(subject, StopSession) })

      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

/// Simple string comparison for sorting.
fn string_compare(a: String, b: String) -> order.Order {
  string.compare(a, b)
}

// ============================================================================
// Public API
// ============================================================================

/// Start a new session supervisor.
///
/// Returns the supervisor subject that can be used to manage sessions.
/// Returns an error if the supervisor could not be started.
pub fn start() -> Result(SessionSupervisor, actor.StartError) {
  let initial_state = SupervisorState(sessions: dict.new())

  case
    actor.new(initial_state)
    |> actor.on_message(handle_supervisor_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(reason) -> Error(reason)
  }
}

/// Start a new session with the given ID.
///
/// Returns the session actor subject on success.
/// Returns an error if a session with this ID already exists.
pub fn start_session(
  supervisor: SessionSupervisor,
  session_id: String,
) -> Result(Subject(SessionMessage), SupervisorError) {
  actor.call(supervisor, waiting: 5000, sending: StartSession(_, session_id))
}

/// Stop a session by ID.
///
/// Returns Ok(Nil) on success.
/// Returns an error if no session with this ID exists.
pub fn stop_session(
  supervisor: SessionSupervisor,
  session_id: String,
) -> Result(Nil, SupervisorError) {
  actor.call(supervisor, waiting: 5000, sending: StopSessionById(_, session_id))
}

/// List all active session IDs.
///
/// Returns a sorted list of session ID strings.
pub fn list_sessions(supervisor: SessionSupervisor) -> List(String) {
  actor.call(supervisor, waiting: 5000, sending: ListSessions)
}

/// Get a session subject by ID.
///
/// Returns the session actor subject on success.
/// Returns an error if no session with this ID exists.
pub fn get_session(
  supervisor: SessionSupervisor,
  session_id: String,
) -> Result(Subject(SessionMessage), SupervisorError) {
  actor.call(supervisor, waiting: 5000, sending: GetSession(_, session_id))
}

/// Stop the supervisor and all its sessions.
///
/// Gracefully terminates all sessions before stopping the supervisor.
pub fn stop(supervisor: SessionSupervisor) -> Nil {
  actor.call(supervisor, waiting: 5000, sending: StopSupervisor)
}
