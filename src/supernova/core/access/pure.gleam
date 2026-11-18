//// Access Control — Pure Functions
////
//// Every access decision is made here: pure, deterministic, no FFI. The actor
//// module only stores state and performs I/O.
////
//// ## Usage
////
//// ```gleam
//// let config = types.default_config()
//// pure.decide(config, "telegram:123") // -> Denied
//// ```

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/core/access/types.{
  type AccessConfig, type ChatDecision, type Command, type Decision,
  type PersistedState, type Role, AccessConfig, AddAccess, AddChat, Admin,
  Allowed, Allowlist, ChatAllowed, ChatDenied, Denied, ListAccess, ListChats,
  Member, Open, PersistedState, RemoveAccess, RemoveChat,
}

/// Anti-spam window for denial notices: one calendar day.
pub const day_ms: Int = 86_400_000

// ============================================================================
// Decisions
// ============================================================================

/// Decide whether a principal may use the instance.
///
/// Admin always wins, even in open mode. In allowlist mode only listed
/// principals pass; in open mode every principal is a member. Everything else
/// is denied.
pub fn decide(config: AccessConfig, principal_id: String) -> Decision {
  case list.contains(config.admins, principal_id) {
    True -> Allowed(Admin)
    False ->
      case config.mode {
        Open -> Allowed(Member)
        Allowlist ->
          case list.contains(config.members, principal_id) {
            True -> Allowed(Member)
            False -> Denied
          }
      }
  }
}

/// Decide whether a conversation is allowed for an already-authorized
/// principal.
///
/// Private conversations are always allowed. Groups and servers must be in
/// `allowed_chats`, regardless of the mode (an open instance is still not an
/// open relay for third-party groups).
pub fn decide_chat(
  config: AccessConfig,
  principal_id: String,
  chat_key: String,
  is_private: Bool,
) -> ChatDecision {
  case decide(config, principal_id) {
    Denied -> ChatDenied
    Allowed(_) ->
      case is_private || list.contains(config.allowed_chats, chat_key) {
        True -> ChatAllowed
        False -> ChatDenied
      }
  }
}

/// Human-readable Portuguese role name used in replies.
pub fn role_name(role: Role) -> String {
  case role {
    Admin -> "admin"
    Member -> "membro"
  }
}

/// Whether a principal may run `/acesso` commands. Only admins may.
pub fn can_manage_access(decision: Decision) -> Bool {
  case decision {
    Allowed(Admin) -> True
    Allowed(Member) -> False
    Denied -> False
  }
}

// ============================================================================
// Command Parsing
// ============================================================================

/// Parse an `/acesso` command.
///
/// Accepted forms:
/// - `/acesso listar`
/// - `/acesso adicionar <principal> [admin|membro]` (defaults to member)
/// - `/acesso remover <principal>`
/// - `/acesso chat adicionar <id>`
/// - `/acesso chat remover <id>`
/// - `/acesso chat listar`
///
/// Telegram group commands may carry a bot suffix (`/acesso@MyBot`); it is
/// ignored. Command words are case-insensitive, identifiers are preserved.
pub fn parse_command(text: String) -> Option(Command) {
  let tokens =
    text
    |> string.trim
    |> string.split(" ")
    |> list.filter(fn(token) { token != "" })

  case tokens {
    [command, ..args] ->
      case normalize_command(command) {
        "/acesso" -> parse_access_args(args)
        _ -> None
      }
    [] -> None
  }
}

fn parse_access_args(args: List(String)) -> Option(Command) {
  case args {
    [subcommand, ..rest] ->
      case string.lowercase(subcommand) {
        "listar" ->
          case rest {
            [] -> Some(ListAccess)
            _ -> None
          }
        "adicionar" -> parse_add(rest)
        "remover" ->
          case rest {
            [principal] -> Some(RemoveAccess(principal))
            _ -> None
          }
        "chat" -> parse_chat(rest)
        _ -> None
      }
    [] -> None
  }
}

fn parse_add(args: List(String)) -> Option(Command) {
  case args {
    [principal] -> Some(AddAccess(principal, Member))
    [principal, role] ->
      case parse_role(role) {
        Some(role) -> Some(AddAccess(principal, role))
        None -> None
      }
    _ -> None
  }
}

fn parse_chat(args: List(String)) -> Option(Command) {
  case args {
    [action, chat_id] ->
      case string.lowercase(action) {
        "adicionar" -> Some(AddChat(chat_id))
        "remover" -> Some(RemoveChat(chat_id))
        _ -> None
      }
    [action] ->
      case string.lowercase(action) {
        "listar" -> Some(ListChats)
        _ -> None
      }
    _ -> None
  }
}

fn parse_role(role: String) -> Option(Role) {
  case string.lowercase(role) {
    "admin" -> Some(Admin)
    "membro" -> Some(Member)
    "member" -> Some(Member)
    _ -> None
  }
}

fn normalize_command(token: String) -> String {
  let lowered = string.lowercase(token)
  case string.split(lowered, "@") {
    [command, ..] -> command
    [] -> lowered
  }
}

// ============================================================================
// Mutations
// ============================================================================

/// Add a principal with the given role.
///
/// Adding an admin removes them from the member list (admin wins). Adding a
/// member never demotes an existing admin.
pub fn add_member(
  config: AccessConfig,
  principal_id: String,
  role: Role,
) -> AccessConfig {
  case role {
    Admin ->
      AccessConfig(
        ..config,
        admins: insert_unique(config.admins, principal_id),
        members: list.filter(config.members, fn(id) { id != principal_id }),
      )
    Member ->
      case list.contains(config.admins, principal_id) {
        True -> config
        False ->
          AccessConfig(
            ..config,
            members: insert_unique(config.members, principal_id),
          )
      }
  }
}

/// Remove a principal. Refuses to remove the last remaining admin.
pub fn remove_member(
  config: AccessConfig,
  principal_id: String,
) -> Result(AccessConfig, String) {
  case
    list.contains(config.admins, principal_id)
    && list.length(config.admins) <= 1
  {
    True -> Error("não é possível remover o último admin")
    False ->
      Ok(
        AccessConfig(
          ..config,
          admins: list.filter(config.admins, fn(id) { id != principal_id }),
          members: list.filter(config.members, fn(id) { id != principal_id }),
        ),
      )
  }
}

/// Authorize a group chat or server.
pub fn add_chat(config: AccessConfig, chat_id: String) -> AccessConfig {
  AccessConfig(
    ..config,
    allowed_chats: insert_unique(config.allowed_chats, chat_id),
  )
}

/// Revoke a group chat or server.
pub fn remove_chat(config: AccessConfig, chat_id: String) -> AccessConfig {
  AccessConfig(
    ..config,
    allowed_chats: list.filter(config.allowed_chats, fn(id) { id != chat_id }),
  )
}

pub fn list_admins(config: AccessConfig) -> List(String) {
  config.admins
}

pub fn list_members(config: AccessConfig) -> List(String) {
  config.members
}

pub fn list_chats(config: AccessConfig) -> List(String) {
  config.allowed_chats
}

// ============================================================================
// Notice Throttling
// ============================================================================

/// Whether a denial notice may be sent now.
///
/// `None` means it was never sent. A non-positive elapsed time (clock skew)
/// suppresses the notice rather than risking spam.
pub fn notice_due(last_notice: Option(Int), now: Int, window_ms: Int) -> Bool {
  case last_notice {
    None -> True
    Some(last) -> now - last >= window_ms
  }
}

// ============================================================================
// Persistence
// ============================================================================

/// Encode the mutable access state as JSON for `<data_dir>/access.json`.
pub fn encode_state(
  config: AccessConfig,
  denied_notices: Dict(String, Int),
  chat_denied_notices: Dict(String, Int),
) -> String {
  json.object([
    #("version", json.int(1)),
    #("admins", json.array(config.admins, json.string)),
    #("members", json.array(config.members, json.string)),
    #("allowed_chats", json.array(config.allowed_chats, json.string)),
    #("denied_notices", json.dict(denied_notices, same_key, json.int)),
    #("chat_denied_notices", json.dict(chat_denied_notices, same_key, json.int)),
  ])
  |> json.to_string
}

/// Decode persisted state, using `base` for missing fields.
///
/// Returns `Error(Nil)` when the JSON is malformed; callers fall back to the
/// configured policy rather than crashing at startup.
pub fn decode_state(
  base: AccessConfig,
  text: String,
) -> Result(PersistedState, Nil) {
  case json.parse(from: text, using: persisted_decoder(base)) {
    Ok(persisted) -> Ok(persisted)
    Error(_) -> Error(Nil)
  }
}

/// Apply the persisted mutable lists on top of the configured policy.
pub fn apply_persisted(
  base: AccessConfig,
  persisted: PersistedState,
) -> AccessConfig {
  AccessConfig(
    ..base,
    admins: persisted.admins,
    members: persisted.members,
    allowed_chats: persisted.allowed_chats,
  )
}

fn persisted_decoder(base: AccessConfig) -> decode.Decoder(PersistedState) {
  use admins <- decode.optional_field(
    "admins",
    base.admins,
    decode.list(decode.string),
  )
  use members <- decode.optional_field(
    "members",
    base.members,
    decode.list(decode.string),
  )
  use allowed_chats <- decode.optional_field(
    "allowed_chats",
    base.allowed_chats,
    decode.list(decode.string),
  )
  use denied_notices <- decode.optional_field(
    "denied_notices",
    dict.new(),
    decode.dict(decode.string, decode.int),
  )
  use chat_denied_notices <- decode.optional_field(
    "chat_denied_notices",
    dict.new(),
    decode.dict(decode.string, decode.int),
  )
  decode.success(PersistedState(
    admins: admins,
    members: members,
    allowed_chats: allowed_chats,
    denied_notices: denied_notices,
    chat_denied_notices: chat_denied_notices,
  ))
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn insert_unique(items: List(String), item: String) -> List(String) {
  case list.contains(items, item) {
    True -> items
    False -> list.append(items, [item])
  }
}

fn same_key(key: String) -> String {
  key
}
