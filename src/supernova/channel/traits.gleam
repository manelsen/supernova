//// What the core needs to know about a channel, declared by the channel.
////
//// The core never matches on channel names: it asks `channel/catalog` for the
//// traits of the channel a message came from. Each channel declares its own
//// traits in `channel/traits/<name>.gleam`; a channel without its own module
//// gets `generic`.

import gleam/option.{type Option, None}

pub type ChannelTraits {
  ChannelTraits(
    name: String,
    /// People on this channel can be closed-group principals
    /// (`<channel>:<user_id>`) in `access.admins`, `access.members` and
    /// `/acesso`.
    has_principals: Bool,
    /// True when a chat id names a private conversation with one person.
    is_private_chat: fn(String) -> Bool,
    /// Key that authorizes a conversation in `access.allowed_chats`.
    chat_key: fn(String) -> String,
    /// Prefix of a group key that `access.allowed_chats` and `/acesso chat`
    /// accept, when the channel has group authorization.
    group_key_prefix: Option(String),
    /// The agenda can reach a person privately on this channel.
    private_delivery: Bool,
    /// Command block of `/help`.
    help_commands: String,
    /// Slash command block of `/commands`.
    command_list: String,
  )
}

pub const basic_help_commands =
  "Commands:\n"
  <> "/help - Show this help\n"
  <> "/start - Start a new session\n"
  <> "/status - Show session status\n"

pub const default_help_commands =
  basic_help_commands <> "/model - Change LLM model\n"

pub const default_command_list =
  "Slash Commands:\n"
  <> "/help - Show this help\n"
  <> "/start - Start a new session\n"
  <> "/status - Show session status\n"
  <> "/model - Change LLM model\n"

/// Traits of a known channel with no rules of its own: no principals, no
/// private chats, chats keyed as `<channel>:<chat_id>`.
pub fn generic(name: String) -> ChannelTraits {
  ChannelTraits(
    name: name,
    has_principals: False,
    is_private_chat: fn(_) { False },
    chat_key: fn(chat_id) { name <> ":" <> chat_id },
    group_key_prefix: None,
    private_delivery: False,
    help_commands: default_help_commands,
    command_list: default_command_list,
  )
}

/// Traits of a channel the catalog does not know.
pub fn unknown(name: String) -> ChannelTraits {
  ChannelTraits(..generic(name), help_commands: basic_help_commands)
}
