//// Slack Router — adapter contract entrypoint for Slack channel.

import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/channel/port
import supernova/llm/provider

pub type SlackRouteResult =
  generic.RouteResult

pub type SlackRouter =
  generic.GenericChannelRouter

/// Starts the Slack router actor.
pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(SlackRouter, actor.StartError) {
  generic.start("slack", llm_config)
}

/// Routes a normalized Slack message through the generic router.
pub fn route(router: SlackRouter, msg: port.ChannelMessage) -> SlackRouteResult {
  generic.route(router, msg)
}

/// Routes a normalized Slack inbound event through the generic router.
pub fn route_inbound(
  router: SlackRouter,
  inbound: port.ChannelInbound,
) -> SlackRouteResult {
  generic.route_inbound(router, inbound)
}
