//// WeChat Work Router — adapter contract entrypoint for WeChat Work channel.

import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/channel/port
import supernova/llm/provider

pub type WechatWorkRouteResult =
  generic.RouteResult

pub type WechatWorkRouter =
  generic.GenericChannelRouter

/// Starts the WeChat Work router actor.
pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(WechatWorkRouter, actor.StartError) {
  generic.start("wechat_work", llm_config)
}

/// Routes a normalized WeChat Work message through the generic router.
pub fn route(
  router: WechatWorkRouter,
  msg: port.ChannelMessage,
) -> WechatWorkRouteResult {
  generic.route(router, msg)
}

/// Routes a normalized WeChat Work inbound event through the generic router.
pub fn route_inbound(
  router: WechatWorkRouter,
  inbound: port.ChannelInbound,
) -> WechatWorkRouteResult {
  generic.route_inbound(router, inbound)
}
