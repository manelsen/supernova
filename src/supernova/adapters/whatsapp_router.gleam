//// WhatsApp Router — adapter contract entrypoint for WhatsApp channel.
////
//// Designed for external bridge integrations (e.g. Whatsmeow HTTP bridge).

import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/channel/port
import supernova/llm/provider

pub type WhatsAppRouteResult =
  generic.RouteResult

pub type WhatsAppRouter =
  generic.GenericChannelRouter

/// Starts the WhatsApp router actor.
pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(WhatsAppRouter, actor.StartError) {
  generic.start("whatsapp", llm_config)
}

/// Routes a normalized WhatsApp message through the generic router.
pub fn route(
  router: WhatsAppRouter,
  msg: port.ChannelMessage,
) -> WhatsAppRouteResult {
  generic.route(router, msg)
}

/// Routes a normalized WhatsApp inbound event through the generic router.
pub fn route_inbound(
  router: WhatsAppRouter,
  inbound: port.ChannelInbound,
) -> WhatsAppRouteResult {
  generic.route_inbound(router, inbound)
}
