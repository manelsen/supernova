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
    /// Longest message a streamed reply can be edited into before it is
    /// split into parts.
    edit_max_length: Int,
    /// The channel shows a typing indicator while a reply streams.
    supports_typing: Bool,
    /// Inbound messages of this channel are routed to a turn.
    routes_inbound: Bool,
    /// The channel has buttons and other interactive components.
    supports_interactions: Bool,
    /// The answer to a button press edits the message that held the button.
    edits_interaction_source: Bool,
    /// How long routing waits for one turn, in milliseconds.
    turn_timeout_ms: Int,
    /// The chat id that reaches a person privately, from their user id.
    private_chat_for: fn(String) -> String,
    /// Messages arrive at the webhook server (`channel/webhook_server`).
    receives_by_webhook: Bool,
  )
}

pub const basic_help_commands =
  "Commands:\n"
  <> "/help - Show this help\n"
  <> "/start - Start a new session\n"
  <> "/status - Show session status\n"
  <> "/vincular - Bring another app to the same agent\n"

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
    // Channels without a documented edit limit keep the whole content.
    edit_max_length: 1_000_000,
    supports_typing: False,
    routes_inbound: False,
    supports_interactions: False,
    edits_interaction_source: False,
    turn_timeout_ms: 30_000,
    private_chat_for: fn(user_id) { user_id },
    receives_by_webhook: False,
  )
}

/// Traits of a channel the catalog does not know.
pub fn unknown(name: String) -> ChannelTraits {
  ChannelTraits(..generic(name), help_commands: basic_help_commands)
}
