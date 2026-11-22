//// Telegram: private chat ids are positive; groups and supergroups are
//// negative. Group chats are authorized as `telegram:<chat_id>`.

import gleam/option.{Some}
import gleam/string
import supernova/channel/chunking
import supernova/channel/traits.{type ChannelTraits, ChannelTraits}

pub fn channel() -> ChannelTraits {
  ChannelTraits(
    name: "telegram",
    has_principals: True,
    is_private_chat: fn(chat_id) {
      !string.starts_with(chat_id, "-") && chat_id != ""
    },
    chat_key: fn(chat_id) { "telegram:" <> chat_id },
    group_key_prefix: Some("telegram:"),
    private_delivery: True,
    help_commands: "Commands:\n"
      <> "/start - Start a new session\n"
      <> "/help - Show this help\n"
      <> "/status - Show session status\n"
      <> "/commands - List all commands\n"
      <> "/reasoning - Toggle reasoning mode\n"
      <> "/model - Change LLM model\n",
    command_list: "Slash Commands:\n"
      <> "/start - Start a new session\n"
      <> "/help - Show this help\n"
      <> "/status - Show session status\n"
      <> "/model - Change LLM model\n"
      <> "/commands - List all commands\n"
      <> "/reasoning - Toggle reasoning mode\n",
    edit_max_length: chunking.telegram_max_length,
    supports_typing: True,
  )
}
