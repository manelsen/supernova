//// Discord: the adapter names private channels `dm:<user_id>` and guild
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
    private_delivery: False,
    help_commands: traits.default_help_commands
      <> "/project - Start project wizard\n",
    command_list: traits.default_command_list,
    edit_max_length: chunking.discord_max_length,
    supports_typing: True,
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
