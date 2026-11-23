//// Telegram router: the shared channel router for `telegram` (see
//// `channel_router`).

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/adapters/channel_router
import supernova/channel/port
import supernova/core/session/supervisor
import supernova/llm/provider

pub type TelegramUpdate =
  port.ChannelMessage

pub type TelegramRouteResult =
  channel_router.RouteResult

pub type TelegramHandlerRouteResult =
  channel_router.HandlerRouteResult

pub type TelegramRouter =
  channel_router.ChannelRouter

pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(TelegramRouter, actor.StartError) {
  channel_router.start("telegram", llm_config)
}

pub fn start_with_session_supervisor(
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> Result(TelegramRouter, actor.StartError) {
  channel_router.start_with_session_supervisor(
    "telegram",
    session_supervisor,
    llm_config,
  )
}

pub fn route(
  router: TelegramRouter,
  message: port.ChannelMessage,
) -> TelegramRouteResult {
  channel_router.route(router, message)
}

pub fn route_inbound(
  router: TelegramRouter,
  inbound: port.ChannelInbound,
) -> TelegramRouteResult {
  channel_router.route_inbound(router, inbound)
}

pub fn route_inbound_for_handler(
  router: TelegramRouter,
  inbound: port.ChannelInbound,
  stream_events: Subject(port.ChannelStreamEvent),
) -> TelegramHandlerRouteResult {
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
      "telegram",
      inbound,
      llm_config,
      state,
      resolve_session,
      session_supervisor,
      stream_events,
    ).1
  }
}
