//// Discord router: the shared channel router for `discord` (see
//// `channel_router`).

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/adapters/channel_common_router
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

/// The router's work for the channel runtime handler, run in the caller's
/// process (the chat's lane) instead of the router's actor: chats no longer
/// wait for each other (PRD-P, P-05, `routing.parallel`). The state lives in
/// ETS, so every lane shares it.
pub fn direct_handler(
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> fn(port.ChannelInbound, Subject(port.ChannelStreamEvent)) ->
  Result(port.ChannelHandlerResult, port.ChannelError) {
  let state = channel_common_router.new_interactive_state()
  fn(inbound, stream_events) {
    channel_common_router.handle_inbound_with_session_supervisor_for_handler(
      "discord",
      inbound,
      llm_config,
      state,
      channel_router.session_resolver("discord"),
      session_supervisor,
      stream_events,
    ).1
  }
}
