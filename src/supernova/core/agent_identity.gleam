//// Agent identity and storage paths derived from a principal id.

import gleam/string

@external(erlang, "supernova_agent_identity_ffi", "encode_principal")
pub fn encode_principal(principal: String) -> String

@external(erlang, "supernova_agent_identity_ffi", "decode_principal")
pub fn decode_principal(encoded: String) -> String

/// Canonical principal for a channel participant.
pub fn principal_id(channel: String, user_id: String) -> String {
  channel <> ":" <> user_id
}

/// Principal for a session key of the form `channel:chat:user`.
pub fn principal_from_session_id(session_id: String) -> String {
  case string.split(session_id, ":") {
    [channel, ..rest] if rest != [] ->
      channel <> ":" <> last_segment(string.join(rest, ":"))
    _ -> session_id
  }
}

fn last_segment(value: String) -> String {
  case string.split(value, ":") {
    [] -> value
    parts -> {
      let assert Ok(last) = list_last(parts)
      last
    }
  }
}

fn list_last(items: List(a)) -> Result(a, Nil) {
  case items {
    [] -> Error(Nil)
    [only] -> Ok(only)
    [_, ..rest] -> list_last(rest)
  }
}

/// Agent directory under `<data_dir>/agents`.
pub fn agent_dir(data_dir: String, principal: String) -> String {
  data_dir <> "/agents/" <> encode_principal(principal)
}

/// Tool workspace for a principal.
pub fn workspace_dir(data_dir: String, principal: String) -> String {
  agent_dir(data_dir, principal) <> "/workspace"
}

/// Private identity directory; never exposed to tools.
pub fn self_dir(data_dir: String, principal: String) -> String {
  agent_dir(data_dir, principal) <> "/self"
}

/// User component of a principal id.
pub fn user_id_from_principal(principal: String) -> String {
  last_segment(principal)
}
