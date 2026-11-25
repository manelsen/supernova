//// Sim router: the shared channel router for `sim` (see
//// `channel_router`).

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/adapters/channel_router
import supernova/channel/port
import supernova/core/session/supervisor
import supernova/llm/provider

pub type SimUpdate =
  port.ChannelMessage

pub type SimRouteResult =
  channel_router.RouteResult

pub type SimHandlerRouteResult =
  channel_router.HandlerRouteResult

pub type SimRouter =
  channel_router.ChannelRouter

pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(SimRouter, actor.StartError) {
  channel_router.start("sim", llm_config)
}

pub fn start_with_session_supervisor(
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> Result(SimRouter, actor.StartError) {
  channel_router.start_with_session_supervisor(
    "sim",
    session_supervisor,
    llm_config,
  )
}

pub fn route_inbound_for_handler(
  router: SimRouter,
  inbound: port.ChannelInbound,
  stream_events: Subject(port.ChannelStreamEvent),
) -> SimHandlerRouteResult {
  channel_router.route_inbound_for_handler(router, inbound, stream_events)
}
