//// Unified Channel Router — shared router for channels without specific session logic.
////
//// This module provides a router implementation that all channel adapters
//// can use, eliminating code duplication. Channels like Matrix, Slack, etc.
//// use this shared router instead of duplicating the same pattern.
////
//// ## Usage
////
//// ```gleam
//// // For channels without session manager (Matrix, Slack, etc.)
//// let resolver = session.without_manager("matrix")
//// let assert Ok(router) = unified_router.start("matrix", llm_config, resolver)
////
//// // Route a message
//// let result = unified_router.route(router, message)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/adapters/channel_common_router
import supernova/channel/port
import supernova/channel/session.{type SessionResolver}
import supernova/llm/provider

/// Router result type.
pub type RouteResult =
  Result(port.ChannelReply, port.ChannelError)

/// Messages for the router actor.
pub type RouterMessage {
  HandleInbound(reply_to: Subject(RouteResult), inbound: port.ChannelInbound)
}

/// Router state.
type RouterState {
  RouterState(
    expected_channel: String,
    llm_config: provider.ProviderConfig,
    interactive_state: channel_common_router.InteractiveRouterState,
    session_resolver: SessionResolver,
  )
}

/// The router handle.
pub type UnifiedRouter =
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
      let #(next_state, result) =
        handle_inbound(
          state.expected_channel,
          inbound,
          state.llm_config,
          state.interactive_state,
          make_resolve_session(state.session_resolver),
        )
      actor.send(reply_to, result)
      actor.continue(
        RouterState(
          ..state,
          interactive_state: channel_common_router.InteractiveRouterState(
            session_configs: next_state.session_configs,
            session_profiles: next_state.session_profiles,
          ),
        ),
      )
    }
  }
}

/// Handle inbound messages and interaction callbacks through the shared flow.
fn handle_inbound(
  expected_channel: String,
  inbound: port.ChannelInbound,
  default_llm_config: provider.ProviderConfig,
  state: channel_common_router.InteractiveRouterState,
  resolve_session: channel_common_router.ResolveSessionFromParticipant,
) -> #(channel_common_router.InteractiveRouterState, RouteResult) {
  channel_common_router.handle_inbound(
    expected_channel,
    inbound,
    default_llm_config,
    state,
    resolve_session,
  )
}

/// Convert SessionResolver to the ResolveSessionFromParticipant callback.
fn make_resolve_session(
  resolver: SessionResolver,
) -> channel_common_router.ResolveSessionFromParticipant {
  fn(channel_id, user_id) { resolver.resolve(channel_id, user_id) }
}

// ============================================================================
// Public API
// ============================================================================

/// Start a new unified message router.
///
/// For channels without a dedicated session manager (Matrix, Slack, etc.),
/// this provides a shared router implementation.
pub fn start(
  expected_channel: String,
  llm_config: provider.ProviderConfig,
  session_resolver: SessionResolver,
) -> Result(UnifiedRouter, actor.StartError) {
  let initial_state =
    RouterState(
      expected_channel: expected_channel,
      llm_config: llm_config,
      interactive_state: channel_common_router.new_interactive_state(),
      session_resolver: session_resolver,
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

/// Route an incoming message through the unified router.
pub fn route(router: UnifiedRouter, msg: port.ChannelMessage) -> RouteResult {
  route_inbound(router, port.inbound_message(msg))
}

/// Route an inbound event (message or interaction) through the unified router.
pub fn route_inbound(
  router: UnifiedRouter,
  inbound: port.ChannelInbound,
) -> RouteResult {
  actor.call(router, waiting: 30_000, sending: HandleInbound(_, inbound))
}
