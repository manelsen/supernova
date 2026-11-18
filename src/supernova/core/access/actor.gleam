//// Access Control — Actor
////
//// Owns the mutable access lists and the anti-spam notice timestamps.
//// Decisions are delegated to `pure`; this module only stores state and does
//// I/O. Runtime changes are persisted atomically to
//// `<data_dir>/access.json`.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(access) = actor.start(config, "/var/lib/supernova")
//// actor.check(access, "telegram:123") // -> Allowed(Admin)
//// ```

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import supernova/core/access/pure
import supernova/core/access/types.{
  type AccessConfig, type ChatDecision, type Decision,
  type PersistedState as PersistedStateType, type Role, ChatDenied, Denied,
  PersistedState, empty_persisted,
}
import supernova/core/safe_call

/// Every actor call fails closed within two seconds.
const call_timeout_ms = 2000

// ============================================================================
// FFI
// ============================================================================

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_now() -> Int

@external(erlang, "supernova_file_system_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn ffi_write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ffi_ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_access_ffi", "rename")
fn ffi_rename(from: String, to: String) -> Result(Nil, String)

// ============================================================================
// State
// ============================================================================

/// Actor state.
pub type State {
  State(
    base: AccessConfig,
    config: AccessConfig,
    persisted: PersistedStateType,
    data_dir: String,
    clock: fn() -> Int,
  )
}

/// Messages handled by the access actor.
pub type AccessMessage {
  Check(reply_to: Subject(Decision), principal_id: String)
  CheckChat(
    reply_to: Subject(ChatDecision),
    principal_id: String,
    chat_key: String,
    is_private: Bool,
  )
  IsAdmin(reply_to: Subject(Bool), principal_id: String)
  TakeDeniedNotice(reply_to: Subject(Bool), principal_id: String)
  TakeChatDeniedNotice(reply_to: Subject(Bool), chat_key: String)
  AddMember(
    reply_to: Subject(Result(Nil, String)),
    principal_id: String,
    role: Role,
  )
  RemoveMember(reply_to: Subject(Result(Nil, String)), principal_id: String)
  AddChat(reply_to: Subject(Result(Nil, String)), chat_id: String)
  RemoveChat(reply_to: Subject(Result(Nil, String)), chat_id: String)
  ListMembers(reply_to: Subject(List(String)))
  ListChats(reply_to: Subject(List(String)))
  ListAdmins(reply_to: Subject(List(String)))
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running access actor.
pub type AccessActor =
  Subject(AccessMessage)

// ============================================================================
// Persistence
// ============================================================================

fn access_path(data_dir: String) -> String {
  data_dir <> "/access.json"
}

fn load_state(
  config: AccessConfig,
  data_dir: String,
  clock: fn() -> Int,
) -> State {
  case ffi_read_file(access_path(data_dir)) {
    Ok(text) ->
      case pure.decode_state(config, text) {
        Ok(persisted) -> {
          let state =
            State(
              base: config,
              config: pure.apply_persisted(config, persisted),
              persisted: persisted,
              data_dir: data_dir,
              clock: clock,
            )
          // A legacy full-list file and any pre-delta format is rewritten in
          // the current shape as soon as it is read.
          persist_best_effort(state)
          state
        }
        Error(_) -> fresh_state(config, data_dir, clock)
      }
    Error(_) -> fresh_state(config, data_dir, clock)
  }
}

fn fresh_state(
  config: AccessConfig,
  data_dir: String,
  clock: fn() -> Int,
) -> State {
  State(
    base: config,
    config: config,
    persisted: empty_persisted(),
    data_dir: data_dir,
    clock: clock,
  )
}

/// Write the whole state to a temporary file, then rename it over
/// `access.json` so readers never observe a partial file.
fn persist_state(state: State) -> Result(Nil, String) {
  use _ <- result.try(ffi_ensure_dir(state.data_dir))
  let path = access_path(state.data_dir)
  let temp_path = path <> ".tmp"
  use _ <- result.try(ffi_write_file(
    temp_path,
    pure.encode_state(state.persisted),
  ))
  ffi_rename(temp_path, path)
}

fn persist_best_effort(state: State) -> Nil {
  let _ = persist_state(state)
  Nil
}

// ============================================================================
// Notice Throttling
// ============================================================================

fn take_notice(
  notices: Dict(String, Int),
  key: String,
  now: Int,
) -> #(Dict(String, Int), Bool) {
  let last_notice = case dict.get(notices, key) {
    Ok(timestamp) -> Some(timestamp)
    Error(_) -> None
  }
  case pure.notice_due(last_notice, now, pure.day_ms) {
    True -> #(dict.insert(notices, key, now), True)
    False -> #(notices, False)
  }
}

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: State,
  message: AccessMessage,
) -> actor.Next(State, AccessMessage) {
  case message {
    Check(reply_to, principal_id) -> {
      actor.send(reply_to, pure.decide(state.config, principal_id))
      actor.continue(state)
    }

    CheckChat(reply_to, principal_id, chat_key, is_private) -> {
      let decision =
        pure.decide_chat(state.config, principal_id, chat_key, is_private)
      actor.send(reply_to, decision)
      actor.continue(state)
    }

    IsAdmin(reply_to, principal_id) -> {
      let is_admin =
        pure.decide(state.config, principal_id) |> pure.can_manage_access
      actor.send(reply_to, is_admin)
      actor.continue(state)
    }

    TakeDeniedNotice(reply_to, principal_id) -> {
      let now = state.clock()
      let #(notices, due) =
        take_notice(state.persisted.denied_notices, principal_id, now)
      case due {
        True -> {
          let new_state =
            State(
              ..state,
              persisted: PersistedState(
                added: state.persisted.added,
                removed: state.persisted.removed,
                denied_notices: notices,
                chat_denied_notices: state.persisted.chat_denied_notices,
              ),
            )
          persist_best_effort(new_state)
          actor.send(reply_to, True)
          actor.continue(new_state)
        }
        False -> {
          actor.send(reply_to, False)
          actor.continue(state)
        }
      }
    }

    TakeChatDeniedNotice(reply_to, chat_key) -> {
      let now = state.clock()
      let #(notices, due) =
        take_notice(state.persisted.chat_denied_notices, chat_key, now)
      case due {
        True -> {
          let new_state =
            State(
              ..state,
              persisted: PersistedState(
                added: state.persisted.added,
                removed: state.persisted.removed,
                denied_notices: state.persisted.denied_notices,
                chat_denied_notices: notices,
              ),
            )
          persist_best_effort(new_state)
          actor.send(reply_to, True)
          actor.continue(new_state)
        }
        False -> {
          actor.send(reply_to, False)
          actor.continue(state)
        }
      }
    }

    AddMember(reply_to, principal_id, role) -> {
      let new_config = pure.add_member(state.config, principal_id, role)
      commit_config(state, new_config, reply_to)
    }

    RemoveMember(reply_to, principal_id) -> {
      case pure.remove_member(state.config, principal_id) {
        Ok(new_config) -> commit_config(state, new_config, reply_to)
        Error(message) -> {
          actor.send(reply_to, Error(message))
          actor.continue(state)
        }
      }
    }

    AddChat(reply_to, chat_id) -> {
      let new_config = pure.add_chat(state.config, chat_id)
      commit_config(state, new_config, reply_to)
    }

    RemoveChat(reply_to, chat_id) -> {
      let new_config = pure.remove_chat(state.config, chat_id)
      commit_config(state, new_config, reply_to)
    }

    ListMembers(reply_to) -> {
      actor.send(reply_to, pure.list_members(state.config))
      actor.continue(state)
    }

    ListChats(reply_to) -> {
      actor.send(reply_to, pure.list_chats(state.config))
      actor.continue(state)
    }

    ListAdmins(reply_to) -> {
      actor.send(reply_to, pure.list_admins(state.config))
      actor.continue(state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

/// Persist a new configuration before committing it to memory. If the write
/// fails the actor keeps the previous policy and reports the error, so the
/// on-disk and in-memory lists never diverge.
fn commit_config(
  state: State,
  new_config: AccessConfig,
  reply_to: Subject(Result(Nil, String)),
) -> actor.Next(State, AccessMessage) {
  let persisted =
    pure.diff_persisted(
      state.base,
      new_config,
      state.persisted.denied_notices,
      state.persisted.chat_denied_notices,
    )
  let new_state = State(..state, config: new_config, persisted: persisted)
  case persist_state(new_state) {
    Ok(_) -> {
      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }
    Error(message) -> {
      actor.send(reply_to, Error(message))
      actor.continue(state)
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start the access actor, reading `<data_dir>/access.json` when present.
pub fn start(
  config: AccessConfig,
  data_dir: String,
) -> Result(AccessActor, actor.StartError) {
  start_with_clock(config, data_dir, ffi_now)
}

/// Start the access actor with an injected clock (tests, deterministic time).
pub fn start_with_clock(
  config: AccessConfig,
  data_dir: String,
  now: fn() -> Int,
) -> Result(AccessActor, actor.StartError) {
  let initial_state = load_state(config, data_dir, now)

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Decide whether a principal may use the instance.
pub fn check(access: AccessActor, principal_id: String) -> Decision {
  call_or(access, Denied, Check(_, principal_id))
}

/// Check with an explicit failure, so callers can distinguish "denied" from
/// "access service unavailable" and fail closed with a generic message.
pub fn try_check(
  access: AccessActor,
  principal_id: String,
) -> Result(Decision, Nil) {
  case safe_call.call(access, call_timeout_ms, Check(_, principal_id)) {
    Ok(decision) -> Ok(decision)
    Error(_) -> Error(Nil)
  }
}

/// Decide whether a conversation is allowed.
pub fn check_chat(
  access: AccessActor,
  principal_id: String,
  chat_key: String,
  is_private: Bool,
) -> ChatDecision {
  call_or(access, ChatDenied, CheckChat(_, principal_id, chat_key, is_private))
}

/// Whether a principal is an admin.
pub fn is_admin(access: AccessActor, principal_id: String) -> Bool {
  call_or(access, False, IsAdmin(_, principal_id))
}

/// Claim the right to send the denial reply for a principal.
///
/// Returns `True` at most once every 24 hours per principal.
pub fn take_denied_notice(access: AccessActor, principal_id: String) -> Bool {
  call_or(access, False, TakeDeniedNotice(_, principal_id))
}

/// Claim the right to send the chat-denied notice for a conversation.
///
/// Returns `True` at most once every 24 hours per chat.
pub fn take_chat_denied_notice(access: AccessActor, chat_key: String) -> Bool {
  call_or(access, False, TakeChatDeniedNotice(_, chat_key))
}

/// Add or promote a principal. Persists before replying.
pub fn add_member(
  access: AccessActor,
  principal_id: String,
  role: Role,
) -> Result(Nil, String) {
  call_or(access, Error("access unavailable"), AddMember(_, principal_id, role))
}

/// Remove a principal, refusing to remove the last admin.
pub fn remove_member(
  access: AccessActor,
  principal_id: String,
) -> Result(Nil, String) {
  call_or(access, Error("access unavailable"), RemoveMember(_, principal_id))
}

/// Authorize a group chat or server.
pub fn add_chat(access: AccessActor, chat_id: String) -> Result(Nil, String) {
  call_or(access, Error("access unavailable"), AddChat(_, chat_id))
}

/// Revoke a group chat or server.
pub fn remove_chat(
  access: AccessActor,
  chat_id: String,
) -> Result(Nil, String) {
  call_or(access, Error("access unavailable"), RemoveChat(_, chat_id))
}

/// List members (admins are listed separately).
pub fn list_members(access: AccessActor) -> List(String) {
  call_or(access, [], ListMembers)
}

/// List authorized group chats and servers.
pub fn list_chats(access: AccessActor) -> List(String) {
  call_or(access, [], ListChats)
}

/// List authorized chats with an explicit failure.
///
/// Unlike `list_chats`, a timeout is not collapsed into an empty list: callers
/// that make destructive decisions must distinguish "no chats" from "unknown".
pub fn try_list_chats(access: AccessActor) -> Result(List(String), Nil) {
  case safe_call.call(access, call_timeout_ms, ListChats) {
    Ok(chats) -> Ok(chats)
    Error(_) -> Error(Nil)
  }
}

/// List admins.
pub fn list_admins(access: AccessActor) -> List(String) {
  call_or(access, [], ListAdmins)
}

/// Stop the actor.
pub fn stop(access: AccessActor) -> Nil {
  call_or(access, Nil, Stop)
}

fn call_or(
  access: AccessActor,
  fallback: reply,
  make_message: fn(Subject(reply)) -> AccessMessage,
) -> reply {
  case safe_call.call(access, call_timeout_ms, make_message) {
    Ok(reply) -> reply
    Error(_) -> fallback
  }
}
