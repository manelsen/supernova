//// Google Chat Router — wrapper integrating google_chat_adapter with generic router.

///
///
import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/adapters/google_chat_adapter
import supernova/channel/port
import supernova/llm/provider

pub type GoogleChatRouteResult =
  generic.RouteResult

pub type GoogleChatRouter =
  generic.GenericChannelRouter

pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(GoogleChatRouter, actor.StartError) {
  generic.start("google_chat", llm_config)
}

pub fn route(
  router: GoogleChatRouter,
  msg: port.ChannelMessage,
) -> GoogleChatRouteResult {
  generic.route(router, msg)
}

pub fn route_inbound(
  router: GoogleChatRouter,
  inbound: port.ChannelInbound,
) -> GoogleChatRouteResult {
  generic.route_inbound(router, inbound)
}

pub fn parse_event(
  event_json: String,
) -> Result(port.ChannelMessage, port.ChannelError) {
  google_chat_adapter.parse_event(event_json)
}

pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  google_chat_adapter.resolve_session_id(msg)
}
