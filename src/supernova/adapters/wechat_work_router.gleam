//// WeChat Work Router — wrapper integrating generic router pattern.
///
import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/channel/port
import supernova/llm/provider

pub type WeChatWorkRouteResult = generic.RouteResult
pub type WeChatWorkRouter = generic.GenericChannelRouter

pub fn start(llm_config: provider.ProviderConfig) -> Result(WeChatWorkRouter, actor.StartError) {
  generic.start("wechat_work", llm_config)
}

pub fn route(router: WeChatWorkRouter, msg: port.ChannelMessage) -> WeChatWorkRouteResult {
  generic.route(router, msg)
}

pub fn route_inbound(router: WeChatWorkRouter, inbound: port.ChannelInbound) -> WeChatWorkRouteResult {
  generic.route_inbound(router, inbound)
}

pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  // WeCom uses FromUserName as user_id
  "wechat_work:" <> msg.channel_id <> ":" <> msg.user_id
}
