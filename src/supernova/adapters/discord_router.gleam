//// Discord Message Router — routes normalized channel messages to sessions.
////
//// This module is the Discord implementation of the channel port contract.
//// Adapters normalize protocol payloads into `port.ChannelMessage` and this
//// router returns `Result(port.ChannelReply, port.ChannelError)`.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(router) = discord_router.start(session_mgr, llm_config)
//// let msg =
////   port.ChannelMessage(
////     id: "msg_1",
////     channel: "discord",
////     channel_id: "channel_123",
////     user_id: "user_456",
////     username: "my-user",
////     content: "hello",
////     is_bot: False,
////     reply_to_id: option.None,
////   )
//// discord_router.route(router, msg)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/adapters/channel_common_router
import supernova/adapters/discord_session
import supernova/channel/port
import supernova/llm/provider

// ============================================================================
// Types
// ============================================================================

/// Backward-compatible alias for the channel port inbound message.
pub type IncomingMessage =
  port.ChannelMessage

/// Router result in the shared channel contract.
pub type RouteResult =
  Result(port.ChannelReply, port.ChannelError)

/// Messages for the router actor.
pub type RouterMessage {
  HandleInbound(reply_to: Subject(RouteResult), inbound: port.ChannelInbound)
}

/// Router state.
type RouterState {
  RouterState(
    session_mgr: discord_session.DiscordSessionManager,
    llm_config: provider.ProviderConfig,
    interactive_state: channel_common_router.InteractiveRouterState,
  )
}

/// The router handle.
pub type DiscordRouter =
  Subject(RouterMessage)

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: RouterState,
  message: RouterMessage,
) -> actor.Next(RouterState, RouterMessage) {
  case message {
    HandleInbound(reply_to, inbound) -> {
      let #(next_interactive_state, result) =
        channel_common_router.handle_inbound(
          "discord",
          inbound,
          state.llm_config,
          state.interactive_state,
          resolve_session(state.session_mgr),
        )
      actor.send(reply_to, result)
      actor.continue(
        RouterState(..state, interactive_state: next_interactive_state),
      )
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start a new Discord message router.
pub fn start(
  session_mgr: discord_session.DiscordSessionManager,
  llm_config: provider.ProviderConfig,
) -> Result(DiscordRouter, actor.StartError) {
  let initial_state =
    RouterState(
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

/// Route an incoming Discord message.
///
/// Returns the routing result with session ID and response.
pub fn route(router: DiscordRouter, msg: port.ChannelMessage) -> RouteResult {
  route_inbound(router, port.inbound_message(msg))
}

/// Route an inbound Discord event (message or interaction).
pub fn route_inbound(
  router: DiscordRouter,
  inbound: port.ChannelInbound,
) -> RouteResult {
  actor.call(router, waiting: 30_000, sending: HandleInbound(_, inbound))
}

fn resolve_session(
  session_mgr: discord_session.DiscordSessionManager,
) -> channel_common_router.ResolveSessionFromParticipant {
  fn(channel_id, user_id) {
    case discord_session.get_or_create(session_mgr, channel_id, user_id) {
      Ok(id) -> id
      Error(_) -> "discord:" <> channel_id <> ":" <> user_id
    }
  }
}
