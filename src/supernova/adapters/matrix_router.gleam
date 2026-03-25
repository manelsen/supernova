//// Matrix Router — adapter contract entrypoint for Matrix channel.

import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/channel/port
import supernova/llm/provider

pub type MatrixRouteResult =
  generic.RouteResult

pub type MatrixRouter =
  generic.GenericChannelRouter

/// Starts the Matrix router actor.
pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(MatrixRouter, actor.StartError) {
  generic.start("matrix", llm_config)
}

/// Routes a normalized Matrix message through the generic router.
pub fn route(
  router: MatrixRouter,
  msg: port.ChannelMessage,
) -> MatrixRouteResult {
  generic.route(router, msg)
}

/// Routes a normalized Matrix inbound event through the generic router.
pub fn route_inbound(
  router: MatrixRouter,
  inbound: port.ChannelInbound,
) -> MatrixRouteResult {
  generic.route_inbound(router, inbound)
}
