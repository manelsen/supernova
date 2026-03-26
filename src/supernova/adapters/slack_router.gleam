//// Slack Router — wrapper that integrates slack_adapter with generic_channel_router.
////
//// This module provides the same interface as the old scaffolded router,
//// but delegates parsing to the new slack_adapter.
////

import gleam/otp/actor
import supernova/adapters/generic_channel_router as generic
import supernova/adapters/slack_adapter
import supernova/channel/port
import supernova/llm/provider

pub type SlackRouteResult =
  generic.RouteResult

pub type SlackRouter =
  generic.GenericChannelRouter

/// Starts the Slack router actor.
/// This now delegates parsing to slack_adapter for proper event normalization.
pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(SlackRouter, actor.StartError) {
  generic.start("slack", llm_config)
}

/// Route a normalized Slack message through the generic router.
/// For raw events, use slack_adapter.parse_event first.
pub fn route(router: SlackRouter, msg: port.ChannelMessage) -> SlackRouteResult {
  generic.route(router, msg)
}

/// Route a normalized Slack inbound event through the generic router.
pub fn route_inbound(
  router: SlackRouter,
  inbound: port.ChannelInbound,
) -> SlackRouteResult {
  generic.route_inbound(router, inbound)
}

/// Parse a raw Slack event JSON into a normalized ChannelMessage.
/// This is the preferred entry point for incoming Slack events.
pub fn parse_event(event_json: String) -> Result(port.ChannelMessage, port.ChannelError) {
  slack_adapter.parse_event(event_json)
}

/// Resolve session ID for a Slack message.
pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  slack_adapter.resolve_session_id(msg)
}
