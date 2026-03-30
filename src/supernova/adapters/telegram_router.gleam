//// Telegram Message Router — routes normalized channel messages to sessions.
////
//// This module is the Telegram implementation of the channel port contract.
//// Adapters normalize protocol payloads into `port.ChannelMessage` and this
//// router returns `Result(port.ChannelReply, port.ChannelError)`.

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import supernova/adapters/channel_common_router
import supernova/channel/port
import supernova/channel/session
import supernova/core/session/supervisor
import supernova/llm/provider

// ============================================================================
// Types
// ============================================================================

/// Backward-compatible alias for the channel port inbound message.
pub type TelegramUpdate =
  port.ChannelMessage

/// Router result in the shared channel contract.
pub type TelegramRouteResult =
  Result(port.ChannelReply, port.ChannelError)

pub type TelegramHandlerRouteResult =
  Result(port.ChannelHandlerResult, port.ChannelError)

pub type TelegramRouterMessage {
  HandleInbound(
    reply_to: Subject(TelegramRouteResult),
    inbound: port.ChannelInbound,
  )
  HandleInboundForHandler(
    reply_to: Subject(TelegramHandlerRouteResult),
    inbound: port.ChannelInbound,
    stream_events: Subject(port.ChannelStreamEvent),
  )
}

type TelegramRouterState {
  TelegramRouterState(
    session_supervisor: Option(supervisor.SessionSupervisor),
    llm_config: provider.ProviderConfig,
    interactive_state: channel_common_router.InteractiveRouterState,
  )
}

pub type TelegramRouter =
  Subject(TelegramRouterMessage)

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: TelegramRouterState,
  message: TelegramRouterMessage,
) -> actor.Next(TelegramRouterState, TelegramRouterMessage) {
  case message {
    HandleInbound(reply_to, inbound) -> {
      let #(next_interactive_state, result) = case state.session_supervisor {
        Some(session_supervisor) ->
          channel_common_router.handle_inbound_with_session_supervisor(
            "telegram",
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve_session,
            session_supervisor,
          )
        None ->
          channel_common_router.handle_inbound(
            "telegram",
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve_session,
          )
      }
      actor.send(reply_to, result)
      actor.continue(
        TelegramRouterState(..state, interactive_state: next_interactive_state),
      )
    }
    HandleInboundForHandler(reply_to, inbound, stream_events) -> {
      let #(next_interactive_state, result) = case state.session_supervisor {
        Some(session_supervisor) ->
          channel_common_router.handle_inbound_with_session_supervisor_for_handler(
            "telegram",
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve_session,
            session_supervisor,
            stream_events,
          )
        None ->
          channel_common_router.handle_inbound_for_handler(
            "telegram",
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve_session,
            stream_events,
          )
      }
      actor.send(reply_to, result)
      actor.continue(
        TelegramRouterState(..state, interactive_state: next_interactive_state),
      )
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Starts the Telegram router actor with session resolution support.
pub fn start(
  llm_config: provider.ProviderConfig,
) -> Result(TelegramRouter, actor.StartError) {
  start_with_optional_session_supervisor(None, llm_config)
}

/// Starts the Telegram router actor backed by the shared session supervisor.
pub fn start_with_session_supervisor(
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> Result(TelegramRouter, actor.StartError) {
  start_with_optional_session_supervisor(Some(session_supervisor), llm_config)
}

fn start_with_optional_session_supervisor(
  session_supervisor: Option(supervisor.SessionSupervisor),
  llm_config: provider.ProviderConfig,
) -> Result(TelegramRouter, actor.StartError) {
  let initial_state =
    TelegramRouterState(
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

/// Routes a normalized Telegram message through the shared inbound pipeline.
pub fn route(
  router: TelegramRouter,
  update: port.ChannelMessage,
) -> TelegramRouteResult {
  route_inbound(router, port.inbound_message(update))
}

/// Routes a normalized Telegram inbound event through the shared inbound pipeline.
pub fn route_inbound(
  router: TelegramRouter,
  inbound: port.ChannelInbound,
) -> TelegramRouteResult {
  actor.call(router, waiting: 30_000, sending: HandleInbound(_, inbound))
}

/// Routes a normalized Telegram inbound event for the channel runtime handler.
pub fn route_inbound_for_handler(
  router: TelegramRouter,
  inbound: port.ChannelInbound,
  stream_events: Subject(port.ChannelStreamEvent),
) -> TelegramHandlerRouteResult {
  actor.call(router, waiting: 30_000, sending: HandleInboundForHandler(
    _,
    inbound,
    stream_events,
  ))
}

fn resolve_session(channel_id: String, _user_id: String) -> String {
  session.telegram_session_id(channel_id)
}
