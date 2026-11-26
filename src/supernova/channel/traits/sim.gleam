//// Sim: the simulation channel used by the harness. The agenda delivers to
//// it, and its chats can be authorized as `sim:<chat_id>`.

import gleam/option.{Some}
import gleam/string
import supernova/channel/traits.{type ChannelTraits, ChannelTraits}

pub fn channel() -> ChannelTraits {
  ChannelTraits(
    ..traits.generic("sim"),
    group_key_prefix: Some("sim:"),
    // The harness names private chats `dm-<person>` (PRD-K: an approval is
    // answered only in a private chat).
    is_private_chat: fn(chat_id) { string.starts_with(chat_id, "dm-") },
    private_delivery: True,
    help_commands: traits.basic_help_commands,
    routes_inbound: True,
    // A whole turn, including birth or a reflection run inside it, with a
    // reasoning model. The sim channel is test-only: a long wait is fine, a
    // premature timeout crashes the HTTP handler with a 500.
    turn_timeout_ms: 300_000,
  )
}
