//// Agent identity and storage paths derived from a principal id.

import gleam/string
import supernova/core/identity/aliases

@external(erlang, "supernova_agent_identity_ffi", "encode_principal")
pub fn encode_principal(principal: String) -> String

@external(erlang, "supernova_agent_identity_ffi", "decode_principal")
pub fn decode_principal(encoded: String) -> String

/// The person behind a channel participant: their canonical principal,
/// with linked identities resolved (PRD-I).
pub fn principal_id(channel: String, user_id: String) -> String {
  aliases.resolve(channel <> ":" <> user_id)
}

/// The person behind a session key of the form `channel:chat:user`, with
/// linked identities resolved: the conversations of every channel of one
/// person live in the same agent folder.
pub fn principal_from_session_id(session_id: String) -> String {
  case string.split(session_id, ":") {
    [channel, ..rest] if rest != [] ->
      aliases.resolve(channel <> ":" <> last_segment(string.join(rest, ":")))
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
