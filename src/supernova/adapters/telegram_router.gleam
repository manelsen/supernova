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
