//// Slack Router — full session/stream router equivalent to Discord and Telegram.
////
//// This module upgrades the Slack adapter from a thin generic_channel_router
//// wrapper to a first-class router with supervisor-backed session trails,
//// streaming support, and interactive callback handling.

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import supernova/adapters/channel_common_router
import supernova/adapters/slack_adapter
import supernova/channel/port
import supernova/core/session/supervisor
import supernova/llm/provider

// ============================================================================
// Types
// ============================================================================

/// Router result in the shared channel contract.
pub type SlackRouteResult =
  Result(port.ChannelReply, port.ChannelError)

pub type SlackHandlerRouteResult =
  Result(port.ChannelHandlerResult, port.ChannelError)

/// Messages for the router actor.
pub type SlackRouterMessage {
  HandleInbound(
    reply_to: Subject(SlackRouteResult),
    inbound: port.ChannelInbound,
  )
  HandleInboundForHandler(
    reply_to: Subject(SlackHandlerRouteResult),
    inbound: port.ChannelInbound,
    stream_events: Subject(port.ChannelStreamEvent),
  )
}

type SlackRouterState {
  SlackRouterState(
    session_supervisor: Option(supervisor.SessionSupervisor),
    llm_config: provider.ProviderConfig,
    interactive_state: channel_common_router.InteractiveRouterState,
  )
}

/// The router handle.
pub type SlackRouter =
  Subject(SlackRouterMessage)

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: SlackRouterState,
  message: SlackRouterMessage,
) -> actor.Next(SlackRouterState, SlackRouterMessage) {
  case message {
    HandleInbound(reply_to, inbound) -> {
      let #(next_interactive_state, result) = case state.session_supervisor {
        Some(session_supervisor) ->
          channel_common_router.handle_inbound_with_session_supervisor(
            "slack",
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve_session,
            session_supervisor,
          )
        None ->
          channel_common_router.handle_inbound(
            "slack",
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve_session,
          )
      }
      actor.send(reply_to, result)
      actor.continue(
        SlackRouterState(..state, interactive_state: next_interactive_state),
      )
    }
    HandleInboundForHandler(reply_to, inbound, stream_events) -> {
      let #(next_interactive_state, result) = case state.session_supervisor {
        Some(session_supervisor) ->
          channel_common_router.handle_inbound_with_session_supervisor_for_handler(
            "slack",
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve_session,
            session_supervisor,
            stream_events,
          )
        None ->
          channel_common_router.handle_inbound_for_handler(
            "slack",
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve_session,
            stream_events,
          )
      }
      actor.send(reply_to, result)
      actor.continue(
        SlackRouterState(..state, interactive_state: next_interactive_state),
      )
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start a new Slack message router.
pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(SlackRouter, actor.StartError) {
  start_with_optional_session_supervisor(None, llm_config)
}

/// Start a new Slack message router backed by the shared session supervisor.
pub fn start_with_session_supervisor(
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> Result(SlackRouter, actor.StartError) {
  start_with_optional_session_supervisor(Some(session_supervisor), llm_config)
}

fn start_with_optional_session_supervisor(
  session_supervisor: Option(supervisor.SessionSupervisor),
  llm_config: provider.ProviderConfig,
) -> Result(SlackRouter, actor.StartError) {
  let initial_state =
    SlackRouterState(
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

/// Route a normalized Slack message through the inbound pipeline.
pub fn route(router: SlackRouter, msg: port.ChannelMessage) -> SlackRouteResult {
  route_inbound(router, port.inbound_message(msg))
}

/// Route a normalized Slack inbound event through the inbound pipeline.
pub fn route_inbound(
  router: SlackRouter,
  inbound: port.ChannelInbound,
) -> SlackRouteResult {
  actor.call(router, waiting: 30_000, sending: HandleInbound(_, inbound))
}

/// Route a normalized Slack inbound event for the channel runtime handler.
pub fn route_inbound_for_handler(
  router: SlackRouter,
  inbound: port.ChannelInbound,
  stream_events: Subject(port.ChannelStreamEvent),
) -> SlackHandlerRouteResult {
  actor.call(router, waiting: 30_000, sending: HandleInboundForHandler(
    _,
    inbound,
    stream_events,
  ))
}

/// Parse a raw Slack event JSON into a normalized ChannelMessage.
pub fn parse_event(
  event_json: String,
) -> Result(port.ChannelMessage, port.ChannelError) {
  slack_adapter.parse_event(event_json)
}

/// Resolve session ID for a Slack message.
pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  slack_adapter.resolve_session_id(msg)
}

fn resolve_session(channel_id: String, user_id: String) -> String {
  "slack:" <> channel_id <> ":" <> user_id
}
