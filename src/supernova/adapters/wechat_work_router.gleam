//// WeChat Work Router — wrapper integrating wechat_work_adapter with generic router.

///
import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/adapters/wechat_work_adapter
import supernova/channel/port
import supernova/llm/provider

pub type WeChatWorkRouteResult =
  generic.RouteResult

pub type WeChatWorkRouter =
  generic.GenericChannelRouter

pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(WeChatWorkRouter, actor.StartError) {
  generic.start("wechat_work", llm_config)
}

pub fn route(
  router: WeChatWorkRouter,
  msg: port.ChannelMessage,
) -> WeChatWorkRouteResult {
  generic.route(router, msg)
}

pub fn route_inbound(
  router: WeChatWorkRouter,
  inbound: port.ChannelInbound,
) -> WeChatWorkRouteResult {
  generic.route_inbound(router, inbound)
}

pub fn parse_event(
  event_json: String,
) -> Result(port.ChannelMessage, port.ChannelError) {
  wechat_work_adapter.parse_event(event_json)
}

pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  wechat_work_adapter.resolve_session_id(msg)
}
