//// Matrix Router — wrapper that integrates matrix_adapter with generic_channel_router.
////
//// This module provides the same interface as the old scaffolded router,
//// but delegates parsing to the new matrix_adapter.
////

import gleam/otp/actor
import gleam/erlang/process.{type Subject}
import supernova/adapters/generic_channel_router as generic
import supernova/adapters/matrix_adapter
import supernova/channel/port
import supernova/llm/provider

pub type MatrixRouteResult =
  generic.RouteResult

pub type MatrixRouter =
  generic.GenericChannelRouter

/// Starts the Matrix router actor.
/// This now delegates parsing to matrix_adapter for proper event normalization.
pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(MatrixRouter, actor.StartError) {
  generic.start("matrix", llm_config)
}

/// Route a normalized Matrix message through the generic router.
/// For raw events, use matrix_adapter.parse_event first.
pub fn route(router: MatrixRouter, msg: port.ChannelMessage) -> MatrixRouteResult {
  generic.route(router, msg)
}

/// Route a normalized Matrix inbound event through the generic router.
pub fn route_inbound(
  router: MatrixRouter,
  inbound: port.ChannelInbound,
) -> MatrixRouteResult {
  generic.route_inbound(router, inbound)
}

/// Parse a raw Matrix event JSON into a normalized ChannelMessage.
/// This is the preferred entry point for incoming Matrix events.
pub fn parse_event(event_json: String) -> Result(port.ChannelMessage, port.ChannelError) {
  matrix_adapter.parse_event(event_json)
}

/// Resolve session ID for a Matrix message.
pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  matrix_adapter.resolve_session_id(msg)
}
