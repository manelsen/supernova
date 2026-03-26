//// Lark Router — wrapper integrating lark_adapter with generic router.
///
///
import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/adapters/lark_adapter
import supernova/channel/port
import supernova/llm/provider

pub type LarkRouteResult = generic.RouteResult
pub type LarkRouter = generic.GenericChannelRouter

pub fn start(llm_config: provider.ProviderConfig) -> Result(LarkRouter, actor.StartError) {
  generic.start("lark", llm_config)
}

pub fn route(router: LarkRouter, msg: port.ChannelMessage) -> LarkRouteResult {
  generic.route(router, msg)
}

pub fn route_inbound(router: LarkRouter, inbound: port.ChannelInbound) -> LarkRouteResult {
  generic.route_inbound(router, inbound)
}

pub fn parse_event(event_json: String) -> Result(port.ChannelMessage, port.ChannelError) {
  lark_adapter.parse_event(event_json)
}

pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  lark_adapter.resolve_session_id(msg)
}
