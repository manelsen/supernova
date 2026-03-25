//// Telegram Message Router — routes normalized channel messages to sessions.
////
//// This module is the Telegram implementation of the channel port contract.
//// Adapters normalize protocol payloads into `port.ChannelMessage` and this
//// router returns `Result(port.ChannelReply, port.ChannelError)`.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/adapters/channel_common_router
import supernova/adapters/telegram_session
import supernova/channel/port
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

pub type TelegramRouterMessage {
  HandleInbound(
    reply_to: Subject(TelegramRouteResult),
    inbound: port.ChannelInbound,
  )
}

type TelegramRouterState {
  TelegramRouterState(
    session_mgr: telegram_session.TelegramSessionManager,
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
      let #(next_interactive_state, result) =
        channel_common_router.handle_inbound(
          "telegram",
          inbound,
          state.llm_config,
          state.interactive_state,
          resolve_session(state.session_mgr),
        )
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
  session_mgr: telegram_session.TelegramSessionManager,
  llm_config: provider.ProviderConfig,
) -> Result(TelegramRouter, actor.StartError) {
  let initial_state =
    TelegramRouterState(
      session_mgr: session_mgr,
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

fn resolve_session(
  session_mgr: telegram_session.TelegramSessionManager,
) -> channel_common_router.ResolveSessionFromParticipant {
  fn(channel_id, _user_id) {
    case telegram_session.get_or_create(session_mgr, channel_id) {
      Ok(id) -> id
      Error(_) -> "telegram:" <> channel_id
    }
  }
}
