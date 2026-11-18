//// Principal — the identity of a person talking to Supernova.
////
//// A principal is the channel-scoped sender identity, deliberately separate
//// from the conversation session: in a group chat many principals share one
//// session, and budgets must be accounted per person.
////
//// Format: `<channel>:<user_id>` (for example `telegram:123`).

import gleam/list
import gleam/string

/// A channel-scoped person identity.
pub type Principal {
  Principal(channel: String, user_id: String)
}

/// Render a principal in persisted/configured form.
pub fn principal_id(principal: Principal) -> String {
  principal.channel <> ":" <> principal.user_id
}

/// Parse `<channel>:<user_id>`.
///
/// The user id may itself contain colons (Discord guild-scoped chat ids), so
/// only the first colon separates the channel from the sender.
pub fn parse(id: String) -> Result(Principal, Nil) {
  let trimmed = string.trim(id)
  case string.split(trimmed, ":") {
    [channel, rest, ..] if channel != "" && rest != "" -> {
      let user_id = string.drop_start(trimmed, string.length(channel) + 1)
      Ok(Principal(channel: channel, user_id: user_id))
    }
    _ -> Error(Nil)
  }
}

/// True when the id is a well-formed principal id for a supported channel.
pub fn is_valid_id(id: String) -> Bool {
  case parse(id) {
    Ok(principal) ->
      list.contains(["telegram", "discord"], principal.channel)
      && string.trim(id) == id
      && !string.contains(principal.user_id, " ")
    Error(_) -> False
  }
}

/// Treat empty and placeholder senders as missing.
pub fn from_sender(channel: String, user_id: String) -> Result(Principal, Nil) {
  case string.trim(user_id) {
    "" -> Error(Nil)
    "unknown" -> Error(Nil)
    trimmed -> {
      case string.trim(channel) {
        "" -> Error(Nil)
        channel_name -> Ok(Principal(channel: channel_name, user_id: trimmed))
      }
    }
  }
}

/// True when the message arrived in a private conversation.
///
/// Telegram private chat ids are positive; groups and supergroups are
/// negative. Discord private channels are represented as `dm:<user_id>` by
/// the adapter layer; guild channels do not have that prefix.
pub fn is_private_chat(channel: String, chat_id: String) -> Bool {
  case channel {
    "telegram" -> !string.starts_with(chat_id, "-") && chat_id != ""
    "discord" -> string.starts_with(chat_id, "dm:")
    _ -> False
  }
}

/// Id used to authorize a group/server conversation.
pub fn chat_principal(channel: String, chat_id: String) -> String {
  case channel {
    "discord" ->
      case string.starts_with(chat_id, "dm:") {
        True -> "discord:dm:" <> string.drop_start(chat_id, 3)
        False -> "discord:guild:" <> chat_id
      }
    _ -> channel <> ":" <> chat_id
  }
}
