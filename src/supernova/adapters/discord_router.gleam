//// Discord router: the shared channel router for `discord` (see
//// `channel_router`).

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/adapters/channel_router
import supernova/channel/port
import supernova/core/session/supervisor
import supernova/llm/provider

pub type IncomingMessage =
  port.ChannelMessage

pub type RouteResult =
  channel_router.RouteResult

pub type HandlerRouteResult =
  channel_router.HandlerRouteResult

pub type DiscordRouter =
  channel_router.ChannelRouter

pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(DiscordRouter, actor.StartError) {
  channel_router.start("discord", llm_config)
}

pub fn start_with_session_supervisor(
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> Result(DiscordRouter, actor.StartError) {
  channel_router.start_with_session_supervisor(
    "discord",
    session_supervisor,
    llm_config,
  )
}

pub fn route(
  router: DiscordRouter,
  message: port.ChannelMessage,
) -> RouteResult {
  channel_router.route(router, message)
}

pub fn route_inbound(
  router: DiscordRouter,
  inbound: port.ChannelInbound,
) -> RouteResult {
  channel_router.route_inbound(router, inbound)
}

pub fn route_inbound_for_handler(
  router: DiscordRouter,
  inbound: port.ChannelInbound,
  stream_events: Subject(port.ChannelStreamEvent),
) -> HandlerRouteResult {
  channel_router.route_inbound_for_handler(router, inbound, stream_events)
}
