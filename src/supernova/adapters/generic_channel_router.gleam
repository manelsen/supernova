//// Generic Channel Router — shared router actor for new channels.
////
//// Provides a minimal actor-based router implementation for channels that
//// share the same contract and do not yet need channel-specific session logic.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/adapters/channel_common_router
import supernova/channel/port
import supernova/llm/provider

pub type RouteResult =
  Result(port.ChannelReply, port.ChannelError)

pub type RouterMessage {
  HandleInbound(reply_to: Subject(RouteResult), inbound: port.ChannelInbound)
}

type RouterState {
  RouterState(
    expected_channel: String,
    llm_config: provider.ProviderConfig,
    interactive_state: channel_common_router.InteractiveRouterState,
  )
}

pub type GenericChannelRouter =
  Subject(RouterMessage)

fn handle_message(
  state: RouterState,
  message: RouterMessage,
) -> actor.Next(RouterState, RouterMessage) {
  case message {
    HandleInbound(reply_to, inbound) -> {
      let #(next_interactive_state, result) =
        channel_common_router.handle_inbound(
          state.expected_channel,
          inbound,
          state.llm_config,
          state.interactive_state,
          resolve_session(state.expected_channel),
        )
      actor.send(reply_to, result)
      actor.continue(
        RouterState(..state, interactive_state: next_interactive_state),
      )
    }
  }
}

/// Starts a generic channel router bound to one expected channel name.
pub fn start(
  expected_channel: String,
  llm_config: provider.ProviderConfig,
) -> Result(GenericChannelRouter, actor.StartError) {
  let initial_state =
    RouterState(
      expected_channel: expected_channel,
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

/// Routes a normalized channel message through the shared inbound pipeline.
pub fn route(
  router: GenericChannelRouter,
  msg: port.ChannelMessage,
) -> RouteResult {
  route_inbound(router, port.inbound_message(msg))
}

/// Routes a normalized inbound event through the shared inbound pipeline.
pub fn route_inbound(
  router: GenericChannelRouter,
  inbound: port.ChannelInbound,
) -> RouteResult {
  actor.call(router, waiting: 30_000, sending: HandleInbound(_, inbound))
}

fn resolve_session(
  channel: String,
) -> channel_common_router.ResolveSessionFromParticipant {
  fn(channel_id, user_id) { channel <> ":" <> channel_id <> ":" <> user_id }
}
