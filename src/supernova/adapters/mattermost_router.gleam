//// Mattermost Router — adapter contract entrypoint for Mattermost channel.

import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/channel/port
import supernova/llm/provider

pub type MattermostRouteResult =
  generic.RouteResult

pub type MattermostRouter =
  generic.GenericChannelRouter

/// Starts the Mattermost router actor.
pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(MattermostRouter, actor.StartError) {
  generic.start("mattermost", llm_config)
}

/// Routes a normalized Mattermost message through the generic router.
pub fn route(
  router: MattermostRouter,
  msg: port.ChannelMessage,
) -> MattermostRouteResult {
  generic.route(router, msg)
}

/// Routes a normalized Mattermost inbound event through the generic router.
pub fn route_inbound(
  router: MattermostRouter,
  inbound: port.ChannelInbound,
) -> MattermostRouteResult {
  generic.route_inbound(router, inbound)
}
