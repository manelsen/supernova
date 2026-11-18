//// Chat lanes — ordered per-chat execution for inbound turns.
////
//// The channel polling loop submits each inbound turn to the lane of its
//// chat and immediately goes back to polling. Different chats run in
//// parallel; turns of the same chat run one at a time, in arrival order.

import supernova/channel/port

/// Run `job` on the lane identified by `key`.
@external(erlang, "supernova_chat_lanes_ffi", "submit")
pub fn submit(key: String, job: fn() -> Nil) -> Nil

/// Number of live lanes (diagnostics and tests).
@external(erlang, "supernova_chat_lanes_ffi", "lane_count")
pub fn lane_count() -> Int

/// Lane key for an inbound event: one lane per channel conversation.
pub fn key_for(inbound: port.ChannelInbound) -> String {
  case inbound {
    port.InboundMessage(msg) -> msg.channel <> ":" <> msg.channel_id
    port.InboundInteraction(interaction) ->
      interaction.channel <> ":" <> interaction.channel_id
  }
}
