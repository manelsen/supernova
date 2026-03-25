//// Google Chat Router — adapter contract entrypoint for Google Chat channel.

import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/channel/port
import supernova/llm/provider

pub type GoogleChatRouteResult =
  generic.RouteResult

pub type GoogleChatRouter =
  generic.GenericChannelRouter

/// Starts the Google Chat router actor.
pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(GoogleChatRouter, actor.StartError) {
  generic.start("google_chat", llm_config)
}

/// Routes a normalized Google Chat message through the generic router.
pub fn route(
  router: GoogleChatRouter,
  msg: port.ChannelMessage,
) -> GoogleChatRouteResult {
  generic.route(router, msg)
}

/// Routes a normalized Google Chat inbound event through the generic router.
pub fn route_inbound(
  router: GoogleChatRouter,
  inbound: port.ChannelInbound,
) -> GoogleChatRouteResult {
  generic.route_inbound(router, inbound)
}
