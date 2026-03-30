//// Matrix Router — full session/stream router equivalent to Discord and Telegram.
////
//// This module upgrades the Matrix adapter from a thin generic_channel_router
//// wrapper to a first-class router with supervisor-backed session trails,
//// streaming support, and command handling.

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import supernova/adapters/channel_common_router
import supernova/adapters/matrix_adapter
import supernova/channel/port
import supernova/core/session/supervisor
import supernova/llm/provider

// ============================================================================
// Types
// ============================================================================

/// Router result in the shared channel contract.
pub type MatrixRouteResult =
  Result(port.ChannelReply, port.ChannelError)

pub type MatrixHandlerRouteResult =
  Result(port.ChannelHandlerResult, port.ChannelError)

/// Messages for the router actor.
pub type MatrixRouterMessage {
  HandleInbound(
    reply_to: Subject(MatrixRouteResult),
    inbound: port.ChannelInbound,
  )
  HandleInboundForHandler(
    reply_to: Subject(MatrixHandlerRouteResult),
    inbound: port.ChannelInbound,
    stream_events: Subject(port.ChannelStreamEvent),
  )
}

type MatrixRouterState {
  MatrixRouterState(
    session_supervisor: Option(supervisor.SessionSupervisor),
    llm_config: provider.ProviderConfig,
    interactive_state: channel_common_router.InteractiveRouterState,
  )
}

/// The router handle.
pub type MatrixRouter =
  Subject(MatrixRouterMessage)

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: MatrixRouterState,
  message: MatrixRouterMessage,
) -> actor.Next(MatrixRouterState, MatrixRouterMessage) {
  case message {
    HandleInbound(reply_to, inbound) -> {
      let #(next_interactive_state, result) = case state.session_supervisor {
        Some(session_supervisor) ->
          channel_common_router.handle_inbound_with_session_supervisor(
            "matrix",
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve_session,
            session_supervisor,
          )
        None ->
          channel_common_router.handle_inbound(
            "matrix",
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve_session,
          )
      }
      actor.send(reply_to, result)
      actor.continue(
        MatrixRouterState(..state, interactive_state: next_interactive_state),
      )
    }
    HandleInboundForHandler(reply_to, inbound, stream_events) -> {
      let #(next_interactive_state, result) = case state.session_supervisor {
        Some(session_supervisor) ->
          channel_common_router.handle_inbound_with_session_supervisor_for_handler(
            "matrix",
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve_session,
            session_supervisor,
            stream_events,
          )
        None ->
          channel_common_router.handle_inbound_for_handler(
            "matrix",
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve_session,
            stream_events,
          )
      }
      actor.send(reply_to, result)
      actor.continue(
        MatrixRouterState(..state, interactive_state: next_interactive_state),
      )
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start a new Matrix message router.
pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(MatrixRouter, actor.StartError) {
  start_with_optional_session_supervisor(None, llm_config)
}

/// Start a new Matrix message router backed by the shared session supervisor.
pub fn start_with_session_supervisor(
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> Result(MatrixRouter, actor.StartError) {
  start_with_optional_session_supervisor(Some(session_supervisor), llm_config)
}

fn start_with_optional_session_supervisor(
  session_supervisor: Option(supervisor.SessionSupervisor),
  llm_config: provider.ProviderConfig,
) -> Result(MatrixRouter, actor.StartError) {
  let initial_state =
    MatrixRouterState(
      session_supervisor: session_supervisor,
      llm_config: llm_config,
      interactive_state: channel_common_router.new_interactive_state(),
    )

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(reason) -> Error(reason)
  }
}

/// Route a normalized Matrix message through the inbound pipeline.
pub fn route(
  router: MatrixRouter,
  msg: port.ChannelMessage,
) -> MatrixRouteResult {
  route_inbound(router, port.inbound_message(msg))
}

/// Route a normalized Matrix inbound event through the inbound pipeline.
pub fn route_inbound(
  router: MatrixRouter,
  inbound: port.ChannelInbound,
) -> MatrixRouteResult {
  actor.call(router, waiting: 30_000, sending: HandleInbound(_, inbound))
}

/// Route a normalized Matrix inbound event for the channel runtime handler.
pub fn route_inbound_for_handler(
  router: MatrixRouter,
  inbound: port.ChannelInbound,
  stream_events: Subject(port.ChannelStreamEvent),
) -> MatrixHandlerRouteResult {
  actor.call(router, waiting: 30_000, sending: HandleInboundForHandler(
    _,
    inbound,
    stream_events,
  ))
}

/// Parse a raw Matrix event JSON into a normalized ChannelMessage.
pub fn parse_event(
  event_json: String,
) -> Result(port.ChannelMessage, port.ChannelError) {
  matrix_adapter.parse_event(event_json)
}

/// Resolve session ID for a Matrix message.
pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  matrix_adapter.resolve_session_id(msg)
}

fn resolve_session(channel_id: String, user_id: String) -> String {
  "matrix:" <> channel_id <> ":" <> user_id
}
