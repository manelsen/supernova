//// Lark Router — adapter contract entrypoint for Lark channel.

import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/channel/port
import supernova/llm/provider

pub type LarkRouteResult =
  generic.RouteResult

pub type LarkRouter =
  generic.GenericChannelRouter

/// Starts the Lark router actor.
pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(LarkRouter, actor.StartError) {
  generic.start("lark", llm_config)
}

/// Routes a normalized Lark message through the generic router.
pub fn route(router: LarkRouter, msg: port.ChannelMessage) -> LarkRouteResult {
  generic.route(router, msg)
}

/// Routes a normalized Lark inbound event through the generic router.
pub fn route_inbound(
  router: LarkRouter,
  inbound: port.ChannelInbound,
) -> LarkRouteResult {
  generic.route_inbound(router, inbound)
}
