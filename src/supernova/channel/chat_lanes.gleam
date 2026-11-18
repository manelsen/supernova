//// Chat lanes — ordered per-chat execution for inbound turns.
////
//// The channel polling loop submits each inbound turn to the lane of its
//// chat and immediately goes back to polling. Different chats run in
//// parallel; turns of the same chat run one at a time, in arrival order.

import supernova/channel/port

/// Run `job` on the lane identified by `key`.
@external(erlang, "supernova_chat_lanes_ffi", "submit")
pub fn submit(key: String, job: fn() -> Nil) -> Bool

/// Submit with explicit limits, used by tests and diagnostics.
@external(erlang, "supernova_chat_lanes_ffi", "submit_with_limits")
pub fn submit_with_limits(
  key: String,
  job: fn() -> Nil,
  max_pending: Int,
  max_lanes: Int,
) -> Bool

/// Number of live lanes (diagnostics and tests).
@external(erlang, "supernova_chat_lanes_ffi", "lane_count")
pub fn lane_count() -> Int

/// Stop accepting keys with `prefix` and wait for their jobs. Returns the
/// number of pending jobs still alive when the timeout expires.
@external(erlang, "supernova_chat_lanes_ffi", "drain")
pub fn drain(prefix: String, timeout_ms: Int) -> Int

/// Lane key for an inbound event: one lane per channel conversation.
pub fn key_for_registry(
  registry_id: String,
  inbound: port.ChannelInbound,
) -> String {
  registry_id <> ":" <> key_for(inbound)
}

pub fn key_for(inbound: port.ChannelInbound) -> String {
  case inbound {
    port.InboundMessage(msg) -> msg.channel <> ":" <> msg.channel_id
    port.InboundInteraction(interaction) ->
      interaction.channel <> ":" <> interaction.channel_id
  }
}
