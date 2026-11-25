//// WhatsApp through the GOWA bridge (PRD-C, C-04). A person is
//// `whatsapp:<phone>`; private chats end in `@s.whatsapp.net`, groups in
//// `@g.us` and are authorized as `whatsapp:<group jid>`. Messages arrive at
//// the webhook server; a reply is sent once, whole (WhatsApp messages are
//// not edited while the answer streams).

import gleam/option.{Some}
import gleam/string
import supernova/channel/traits.{type ChannelTraits, ChannelTraits}

/// Longest message part sent at once.
pub const max_message_length = 4000

pub fn channel() -> ChannelTraits {
  ChannelTraits(
    ..traits.generic("whatsapp"),
    has_principals: True,
    is_private_chat: fn(chat_id) {
      string.ends_with(chat_id, "@s.whatsapp.net")
      || string.ends_with(chat_id, "@lid")
    },
    group_key_prefix: Some("whatsapp:"),
    private_delivery: True,
    help_commands: traits.basic_help_commands,
    edit_max_length: max_message_length,
    routes_inbound: True,
    turn_timeout_ms: 30_000,
    private_chat_for: fn(user_id) {
      case string.contains(user_id, "@") {
        True -> user_id
        False -> user_id <> "@s.whatsapp.net"
      }
    },
    receives_by_webhook: True,
  )
}
