//// Channel router — routes normalized inbound events of one channel to
//// sessions, through the shared pipeline in `channel_common_router`.
////
//// One router per channel, the same for every channel: what differs (the
//// time a turn may take, interactions) comes from the channel's traits.
//// Sessions are keyed `<channel>:<chat_id>:<user_id>`.

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import supernova/adapters/channel_common_router
import supernova/channel/catalog
import supernova/channel/port
import supernova/core/session/supervisor
import supernova/llm/provider

pub type RouteResult =
  Result(port.ChannelReply, port.ChannelError)

pub type HandlerRouteResult =
  Result(port.ChannelHandlerResult, port.ChannelError)

pub opaque type Message {
  HandleInbound(reply_to: Subject(RouteResult), inbound: port.ChannelInbound)
  HandleInboundForHandler(
    reply_to: Subject(HandlerRouteResult),
    inbound: port.ChannelInbound,
    stream_events: Subject(port.ChannelStreamEvent),
  )
}

type State {
  State(
    channel: String,
    session_supervisor: Option(supervisor.SessionSupervisor),
    llm_config: provider.ProviderConfig,
    interactive_state: channel_common_router.InteractiveRouterState,
  )
}

pub opaque type ChannelRouter {
  ChannelRouter(
    channel: String,
    turn_timeout_ms: Int,
    subject: Subject(Message),
  )
}

pub fn start(
  channel: String,
  llm_config: provider.ProviderConfig,
) -> Result(ChannelRouter, actor.StartError) {
  start_with_optional_session_supervisor(channel, None, llm_config)
}

/// A router backed by the shared session supervisor (production).
pub fn start_with_session_supervisor(
  channel: String,
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> Result(ChannelRouter, actor.StartError) {
  start_with_optional_session_supervisor(
    channel,
    Some(session_supervisor),
    llm_config,
  )
}

fn start_with_optional_session_supervisor(
  channel: String,
  session_supervisor: Option(supervisor.SessionSupervisor),
  llm_config: provider.ProviderConfig,
) -> Result(ChannelRouter, actor.StartError) {
  let initial =
    State(
      channel: channel,
      session_supervisor: session_supervisor,
      llm_config: llm_config,
      interactive_state: channel_common_router.new_interactive_state(),
    )
  case actor.new(initial) |> actor.on_message(handle_message) |> actor.start {
    Ok(started) ->
      Ok(ChannelRouter(
        channel: channel,
        turn_timeout_ms: catalog.get(channel).turn_timeout_ms,
        subject: started.data,
      ))
    Error(reason) -> Error(reason)
  }
}

/// Route a normalized message through the shared inbound pipeline.
pub fn route(
  router: ChannelRouter,
  message: port.ChannelMessage,
) -> RouteResult {
  route_inbound(router, port.inbound_message(message))
}

/// Route a normalized inbound event through the shared inbound pipeline.
pub fn route_inbound(
  router: ChannelRouter,
  inbound: port.ChannelInbound,
) -> RouteResult {
  actor.call(
    router.subject,
    waiting: router.turn_timeout_ms,
    sending: HandleInbound(_, inbound),
  )
}

/// Route a normalized inbound event for the channel runtime handler.
pub fn route_inbound_for_handler(
  router: ChannelRouter,
  inbound: port.ChannelInbound,
  stream_events: Subject(port.ChannelStreamEvent),
) -> HandlerRouteResult {
  actor.call(
    router.subject,
    waiting: router.turn_timeout_ms,
    sending: HandleInboundForHandler(_, inbound, stream_events),
  )
}

/// The session id of a chat and a person on one channel. One shape for
/// every channel (PRD-C, C-01): the channel name, the chat and the person.
pub fn session_resolver(
  channel: String,
) -> channel_common_router.ResolveSessionFromParticipant {
  fn(chat_id, user_id) { channel <> ":" <> chat_id <> ":" <> user_id }
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  let resolve = session_resolver(state.channel)
  case message {
    HandleInbound(reply_to, inbound) -> {
      let #(next, result) = case state.session_supervisor {
        Some(session_supervisor) ->
          channel_common_router.handle_inbound_with_session_supervisor(
            state.channel,
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve,
            session_supervisor,
          )
        None ->
          channel_common_router.handle_inbound(
            state.channel,
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve,
          )
      }
      actor.send(reply_to, result)
      actor.continue(State(..state, interactive_state: next))
    }
    HandleInboundForHandler(reply_to, inbound, stream_events) -> {
      let #(next, result) = case state.session_supervisor {
        Some(session_supervisor) ->
          channel_common_router.handle_inbound_with_session_supervisor_for_handler(
            state.channel,
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve,
            session_supervisor,
            stream_events,
          )
        None ->
          channel_common_router.handle_inbound_for_handler(
            state.channel,
            inbound,
            state.llm_config,
            state.interactive_state,
            resolve,
            stream_events,
          )
      }
      actor.send(reply_to, result)
      actor.continue(State(..state, interactive_state: next))
    }
  }
}
