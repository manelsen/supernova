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
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import supernova/core/session/history_store.{type HistoryStore}
import supernova/infra/safe_io
import supernova/llm/provider

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

pub type ResponseLength {
  Short
  Normal
  Verbose
}

pub type SessionPreferences {
  SessionPreferences(
    model_override: Option(String),
    thinking_enabled: Bool,
    reasoning_visible: Bool,
    language: String,
    response_length: ResponseLength,
  )
}

pub fn default_preferences() -> SessionPreferences {
  SessionPreferences(
    model_override: None,
    thinking_enabled: False,
    reasoning_visible: False,
    language: "pt-BR",
    response_length: Normal,
  )
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
  /// Get the full persisted LLM config override (if any)
  GetLLMConfig(reply_to: Subject(Option(provider.ProviderConfig)))
  /// Get session preferences
  GetPreferences(reply_to: Subject(SessionPreferences))
  /// Set the model override
  SetModel(reply_to: Subject(Result(Nil, Nil)), model: String)
  /// Set the full persisted LLM config override
  SetLLMConfig(
    reply_to: Subject(Result(Nil, Nil)),
    llm_config: provider.ProviderConfig,
  )
  /// Replace session preferences
  SetPreferences(
    reply_to: Subject(Result(Nil, Nil)),
    preferences: SessionPreferences,
  )
  /// Clear the model override
  ClearModel(reply_to: Subject(Result(Nil, Nil)))
  /// Clear the full persisted LLM config override
  ClearLLMConfig(reply_to: Subject(Result(Nil, Nil)))
  /// Append one or more messages to the conversation history
  AppendMessages(
    reply_to: Subject(Result(Nil, Nil)),
    messages: List(ChatMessage),
  )
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
    llm_config_override: Option(provider.ProviderConfig),
    preferences: SessionPreferences,
    /// Where the conversation is kept on disk; None keeps it only in memory,
    /// with no limit.
    store: Option(HistoryStore),
    /// Whether the stored conversation was read. A session reads it itself,
    /// on its first message: reading it while starting held up the session
    /// supervisor, and with it every channel's router, for each new session.
    loaded: Bool,
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
  let state = ensure_loaded(state)
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

    GetLLMConfig(reply_to) -> {
      actor.send(reply_to, state.llm_config_override)
      actor.continue(state)
    }

    GetPreferences(reply_to) -> {
      actor.send(reply_to, state.preferences)
      actor.continue(state)
    }

    SetModel(reply_to, model) -> {
      let next_llm_config = case state.llm_config_override {
        Some(config) ->
          Some(provider.ProviderConfig(..config, default_model: model))
        None -> None
      }
      let next_preferences =
        SessionPreferences(..state.preferences, model_override: Some(model))
      let new_state =
        SessionState(
          ..state,
          model_override: Some(model),
          llm_config_override: next_llm_config,
          preferences: next_preferences,
        )
      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    SetLLMConfig(reply_to, llm_config) -> {
      let new_state =
        SessionState(
          ..state,
          model_override: Some(llm_config.default_model),
          llm_config_override: Some(llm_config),
          preferences: SessionPreferences(
            ..state.preferences,
            model_override: Some(llm_config.default_model),
          ),
        )
      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    ClearModel(reply_to) -> {
      let new_state =
        SessionState(
          ..state,
          model_override: None,
          llm_config_override: None,
          preferences: SessionPreferences(
            ..state.preferences,
            model_override: None,
          ),
        )
      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    ClearLLMConfig(reply_to) -> {
      let new_state =
        SessionState(
          ..state,
          model_override: None,
          llm_config_override: None,
          preferences: SessionPreferences(
            ..state.preferences,
            model_override: None,
          ),
        )
      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    SetPreferences(reply_to, preferences) -> {
      let new_state = SessionState(..state, preferences: preferences)
      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    AppendMessages(reply_to, messages) -> {
      let new_state = add_messages(state, messages)
      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Ok(Nil))
      actor.stop()
    }
  }
}

/// Add messages to the conversation. With a store, they are written to disk
/// and the conversation is cut to the store's limit; a write that fails is
/// logged and the turn goes on with the conversation in memory.
fn add_messages(
  state: SessionState,
  messages: List(ChatMessage),
) -> SessionState {
  let history = list.append(state.history, messages)
  case state.store {
    None -> SessionState(..state, history: history)
    Some(store) -> {
      let now = now_ms()
      let stored =
        list.map(messages, fn(message) {
          history_store.StoredMessage(
            role: message.role,
            content: message.content,
            at: now,
          )
        })
      let _ =
        history_store.append(store, state.session_id, stored)
        |> result.map_error(fn(reason) {
          safe_io.println(
            "warn: conversation not saved session="
            <> state.session_id
            <> " error="
            <> reason,
          )
        })
      SessionState(..state, history: cut(history, store.limit))
    }
  }
}

/// The last `limit` messages, opening with something the person said.
fn cut(history: List(ChatMessage), limit: Int) -> List(ChatMessage) {
  history_store.trim(history, limit)
  |> list.drop_while(fn(message) { message.role != "user" })
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

// ============================================================================
// Public API
// ============================================================================

/// Create a new session with the given ID, kept only in memory.
///
/// Returns the session actor subject on success.
pub fn new(session_id: String) -> Result(Session, actor.StartError) {
  start_with(session_id, None, [])
}

/// Create a session whose conversation is kept in `store`: on its first
/// message it reads what the store holds for this session, so a restart
/// does not cut it.
pub fn new_with_store(
  session_id: String,
  store: HistoryStore,
) -> Result(Session, actor.StartError) {
  start_with(session_id, Some(store), [])
}

fn ensure_loaded(state: SessionState) -> SessionState {
  case state.loaded, state.store {
    True, _ | False, None -> SessionState(..state, loaded: True)
    False, Some(store) -> {
      let stored =
        history_store.load(store, state.session_id)
        |> list.map(fn(message) {
          ChatMessage(role: message.role, content: message.content)
        })
      SessionState(
        ..state,
        history: list.append(stored, state.history),
        loaded: True,
      )
    }
  }
}

fn start_with(
  session_id: String,
  store: Option(HistoryStore),
  history: List(ChatMessage),
) -> Result(Session, actor.StartError) {
  let initial_state =
    SessionState(
      session_id: session_id,
      status: Idle,
      history: history,
      model_override: None,
      llm_config_override: None,
      preferences: default_preferences(),
      store: store,
      loaded: False,
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

/// Get the persisted LLM config override (if any).
pub fn get_llm_config(session: Session) -> Option(provider.ProviderConfig) {
  actor.call(session, waiting: 5000, sending: GetLLMConfig)
}

/// Get session preferences.
pub fn get_preferences(session: Session) -> SessionPreferences {
  actor.call(session, waiting: 5000, sending: GetPreferences)
}

/// Set the model override.
pub fn set_model(session: Session, model: String) -> Result(Nil, Nil) {
  actor.call(session, waiting: 5000, sending: SetModel(_, model))
}

/// Set the persisted LLM config override.
pub fn set_llm_config(
  session: Session,
  llm_config: provider.ProviderConfig,
) -> Result(Nil, Nil) {
  actor.call(session, waiting: 5000, sending: SetLLMConfig(_, llm_config))
}

/// Replace session preferences.
pub fn set_preferences(
  session: Session,
  preferences: SessionPreferences,
) -> Result(Nil, Nil) {
  actor.call(session, waiting: 5000, sending: SetPreferences(_, preferences))
}

/// Clear the model override.
pub fn clear_model(session: Session) -> Result(Nil, Nil) {
  actor.call(session, waiting: 5000, sending: ClearModel)
}

/// Clear the persisted LLM config override.
pub fn clear_llm_config(session: Session) -> Result(Nil, Nil) {
  actor.call(session, waiting: 5000, sending: ClearLLMConfig)
}

/// Append one or more messages to the session history.
pub fn append_messages(
  session: Session,
  messages: List(ChatMessage),
) -> Result(Nil, Nil) {
  actor.call(session, waiting: 5000, sending: AppendMessages(_, messages))
}

/// Stop the session.
pub fn stop(session: Session) -> Result(Nil, Nil) {
  actor.call(session, waiting: 5000, sending: Stop)
}
