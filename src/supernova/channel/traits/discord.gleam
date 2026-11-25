//// Discord: the adapter names private chats `dm:<user_id>` and guild
//// channels `<channel_id>@guild:<guild_id>`. A whole guild is authorized as
//// `discord:guild:<guild_id>`.

import gleam/option.{Some}
import gleam/string
import supernova/channel/chunking
import supernova/channel/traits.{type ChannelTraits, ChannelTraits}

pub fn channel() -> ChannelTraits {
  ChannelTraits(
    name: "discord",
    has_principals: True,
    is_private_chat: fn(chat_id) { string.starts_with(chat_id, "dm:") },
    chat_key: chat_key,
    group_key_prefix: Some("discord:guild:"),
    // The adapter opens the DM channel when sending (PRD-D, D-06).
    private_delivery: True,
    help_commands: traits.default_help_commands
      <> "/project - Start project wizard\n",
    command_list: traits.default_command_list,
    edit_max_length: chunking.discord_max_length,
    supports_typing: True,
    routes_inbound: True,
    supports_interactions: True,
    // The message with the buttons is the bot's own: it is edited (D5).
    edits_interaction_source: True,
    turn_timeout_ms: 30_000,
    // The same chat the person writes in: the adapter opens (or reuses)
    // the DM channel when sending.
    private_chat_for: fn(user_id) { "dm:" <> user_id },
    receives_by_webhook: False,
    sends_voice: False,
  )
}

fn chat_key(chat_id: String) -> String {
  case string.starts_with(chat_id, "dm:") {
    True -> "discord:dm:" <> string.drop_start(chat_id, 3)
    False ->
      case string.split(chat_id, "@guild:") {
        [_target, guild] -> "discord:guild:" <> guild
        _ -> "discord:guild:" <> chat_id
      }
  }
}
