//// WhatsApp Router — wrapper integrating whatsapp_adapter with generic router.

///
///
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/adapters/channel_common_router
import supernova/adapters/channel_router
import supernova/adapters/generic_channel_router as generic
import supernova/adapters/whatsapp_adapter
import supernova/channel/port
import supernova/core/session/supervisor
import supernova/llm/provider

pub type WhatsAppRouteResult =
  generic.RouteResult

pub type WhatsAppRouter =
  generic.GenericChannelRouter

pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(WhatsAppRouter, actor.StartError) {
  generic.start("whatsapp", llm_config)
}

pub fn route(
  router: WhatsAppRouter,
  msg: port.ChannelMessage,
) -> WhatsAppRouteResult {
  generic.route(router, msg)
}

pub fn route_inbound(
  router: WhatsAppRouter,
  inbound: port.ChannelInbound,
) -> WhatsAppRouteResult {
  generic.route_inbound(router, inbound)
}

pub fn parse_event(
  event_json: String,
) -> Result(port.ChannelMessage, port.ChannelError) {
  whatsapp_adapter.parse_event(event_json)
}

pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  whatsapp_adapter.resolve_session_id(msg)
}

/// The router's work in the chat's lane, as Telegram's (PRD-P, P-05,
/// `routing.parallel`). Without it, the parallel path had no handler for
/// WhatsApp and dropped every message as "unconfigured channel".
pub fn direct_handler(
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> fn(port.ChannelInbound, Subject(port.ChannelStreamEvent)) ->
  Result(port.ChannelHandlerResult, port.ChannelError) {
  let state = channel_common_router.new_interactive_state()
  fn(inbound, stream_events) {
    channel_common_router.handle_inbound_with_session_supervisor_for_handler(
      "whatsapp",
      inbound,
      llm_config,
      state,
      channel_router.session_resolver("whatsapp"),
      session_supervisor,
      stream_events,
    ).1
  }
}
