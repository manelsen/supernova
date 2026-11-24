//// Matrix router: the shared channel router for `matrix` (see
//// `channel_router`).

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/adapters/channel_router
import supernova/channel/port
import supernova/core/session/supervisor
import supernova/llm/provider

pub type MatrixRouteResult =
  channel_router.RouteResult

pub type MatrixHandlerRouteResult =
  channel_router.HandlerRouteResult

pub type MatrixRouter =
  channel_router.ChannelRouter

pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(MatrixRouter, actor.StartError) {
  channel_router.start("matrix", llm_config)
}

pub fn start_with_session_supervisor(
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> Result(MatrixRouter, actor.StartError) {
  channel_router.start_with_session_supervisor(
    "matrix",
    session_supervisor,
    llm_config,
  )
}

pub fn route(
  router: MatrixRouter,
  message: port.ChannelMessage,
) -> MatrixRouteResult {
  channel_router.route(router, message)
}

pub fn route_inbound(
  router: MatrixRouter,
  inbound: port.ChannelInbound,
) -> MatrixRouteResult {
  channel_router.route_inbound(router, inbound)
}

pub fn route_inbound_for_handler(
  router: MatrixRouter,
  inbound: port.ChannelInbound,
  stream_events: Subject(port.ChannelStreamEvent),
) -> MatrixHandlerRouteResult {
  channel_router.route_inbound_for_handler(router, inbound, stream_events)
}
