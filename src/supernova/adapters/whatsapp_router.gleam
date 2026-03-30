//// WhatsApp Router — wrapper integrating whatsapp_adapter with generic router.

///
///
import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/adapters/whatsapp_adapter
import supernova/channel/port
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
