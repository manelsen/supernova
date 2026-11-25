//// Sim: the simulation channel used by the harness. The agenda delivers to
//// it, and its chats can be authorized as `sim:<chat_id>`.

import gleam/option.{Some}
import supernova/channel/traits.{type ChannelTraits, ChannelTraits}

pub fn channel() -> ChannelTraits {
  ChannelTraits(
    ..traits.generic("sim"),
    group_key_prefix: Some("sim:"),
    private_delivery: True,
    help_commands: traits.basic_help_commands,
    routes_inbound: True,
    // A whole turn, including birth or a reflection run inside it, with a
    // reasoning model. The sim channel is test-only: a long wait is fine, a
    // premature timeout crashes the HTTP handler with a 500.
    turn_timeout_ms: 300_000,
  )
}
