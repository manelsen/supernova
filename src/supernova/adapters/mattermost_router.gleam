//// Mattermost Router — wrapper integrating mattermost_adapter with generic router.
///
///
import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/adapters/mattermost_adapter
import supernova/channel/port
import supernova/llm/provider

pub type MattermostRouteResult = generic.RouteResult
pub type MattermostRouter = generic.GenericChannelRouter

pub fn start(llm_config: provider.ProviderConfig) -> Result(MattermostRouter, actor.StartError) {
  generic.start("mattermost", llm_config)
}

pub fn route(router: MattermostRouter, msg: port.ChannelMessage) -> MattermostRouteResult {
  generic.route(router, msg)
}

pub fn route_inbound(router: MattermostRouter, inbound: port.ChannelInbound) -> MattermostRouteResult {
  generic.route_inbound(router, inbound)
}

pub fn parse_event(event_json: String) -> Result(port.ChannelMessage, port.ChannelError) {
  mattermost_adapter.parse_event(event_json)
}

pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  mattermost_adapter.resolve_session_id(msg)
}
