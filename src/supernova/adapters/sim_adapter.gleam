//// HTTP-driven sim channel used by end-to-end tests and autonomous personas.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import gleam/uri
import mist.{type Connection, type ResponseData}
import supernova/channel/chunking
import supernova/channel/port
import supernova/channel/session
import supernova/config
import supernova/core/closed_group/global as closed_group_global
import supernova/core/closed_group/pure as closed_group_pure

@external(erlang, "supernova_syscall_ffi", "unique_id")
fn unique_id() -> Int

pub type SimEvent {
  SimEvent(
    seq: Int,
    chat_id: String,
    kind: String,
    content: String,
    message_id: Option(String),
  )
}

pub type StoreMessage {
  Append(reply: port.ChannelReply)
  TurnEnd(chat_id: String, session: String, outcome: String)
  Get(reply_to: Subject(List(SimEvent)), chat_id: String, after: Int)
  All(reply_to: Subject(List(SimEvent)))
  Stop
}

type StoreState {
  StoreState(events: List(SimEvent), next_seq: Int)
}

pub type SimChannel {
  SimChannel(store: Subject(StoreMessage), port: Int)
}

pub fn start(
  cfg: config.SimConfig,
  handler: port.ChannelHandler,
) -> Result(#(port.ChannelAdapter, SimChannel), String) {
  case cfg.enabled {
    False -> Error("sim channel is disabled")
    True ->
      case cfg.token {
        None -> Error("Sim is enabled but no token is configured")
        Some(token) -> {
          let assert Ok(store) =
            actor.new(StoreState(events: [], next_seq: 1))
            |> actor.on_message(handle_store)
            |> actor.start
          let store = store.data

          let serve = fn(req: request.Request(Connection)) {
            handle_http(req, token, store, handler)
          }
          case
            serve
            |> mist.new
            |> mist.bind(cfg.bind)
            |> mist.port(cfg.port)
            |> mist.start
          {
            Ok(_) -> {
              let sim = SimChannel(store: store, port: cfg.port)
              let adapter =
                port.ChannelAdapter(
                  name: "sim",
                  send: fn(reply) {
                    append(store, reply)
                    Ok(Nil)
                  },
                  stop_ingress: fn() { Nil },
                  stop: fn() { stop(sim) },
                )
              Ok(#(adapter, sim))
            }
            Error(_) -> Error("failed to start sim HTTP server")
          }
        }
      }
  }
}

pub fn stop(sim: SimChannel) -> Nil {
  actor.send(sim.store, Stop)
  Nil
}

fn handle_store(
  state: StoreState,
  message: StoreMessage,
) -> actor.Next(StoreState, StoreMessage) {
  case message {
    Append(reply) -> {
      let kind = case reply.edit_message_id {
        Some(_) -> "edit"
        None ->
          case reply.typing {
            True -> "typing"
            False -> "send"
          }
      }
      let event =
        SimEvent(
          seq: state.next_seq,
          chat_id: reply.channel_id,
          kind: kind,
          content: reply.content,
          message_id: reply.edit_message_id,
        )
      actor.continue(StoreState(
        events: list.append(state.events, [event]),
        next_seq: state.next_seq + 1,
      ))
    }
    TurnEnd(chat_id, turn_session, outcome) -> {
      let event =
        SimEvent(
          seq: state.next_seq,
          chat_id: chat_id,
          kind: "turn_end",
          content: json.to_string(
            json.object([
              #("session", json.string(turn_session)),
              #("outcome", json.string(outcome)),
            ]),
          ),
          message_id: None,
        )
      actor.continue(StoreState(
        events: list.append(state.events, [event]),
        next_seq: state.next_seq + 1,
      ))
    }
    Get(reply_to, chat_id, after) -> {
      let events =
        state.events
        |> list.filter(fn(event) {
          event.chat_id == chat_id && event.seq > after
        })
      actor.send(reply_to, events)
      actor.continue(state)
    }
    All(reply_to) -> {
      actor.send(reply_to, state.events)
      actor.continue(state)
    }
    Stop -> actor.stop()
  }
}

pub fn all_events(sim: SimChannel) -> List(SimEvent) {
  actor.call(sim.store, waiting: 1000, sending: All)
}

pub fn events(sim: SimChannel, chat_id: String) -> List(SimEvent) {
  actor.call(sim.store, waiting: 1000, sending: Get(_, chat_id, 0))
}

fn append(store: Subject(StoreMessage), reply: port.ChannelReply) -> Nil {
  actor.send(store, Append(reply))
  Nil
}

fn append_turn_end(
  store: Subject(StoreMessage),
  chat_id: String,
  turn_session: String,
  outcome: String,
) -> Nil {
  actor.send(store, TurnEnd(chat_id, turn_session, outcome))
  Nil
}

fn handle_http(
  req: request.Request(Connection),
  token: String,
  store: Subject(StoreMessage),
  handler: port.ChannelHandler,
) -> response.Response(ResponseData) {
  case authorized(req, token) {
    False ->
      json_response(401, json.object([#("error", json.string("unauthorized"))]))
    True ->
      case mist.read_body(req, 1_000_000) {
        Error(_) ->
          json_response(400, json.object([#("error", json.string("body"))]))
        Ok(req_with_body) -> {
          let path = request_path(req)
          case req.method, path {
            _, ["sim", "messages"] ->
              case bit_array.to_string(req_with_body.body) {
                Ok(raw) -> handle_post(req, raw, store, handler)
                Error(_) ->
                  json_response(
                    400,
                    json.object([#("error", json.string("body"))]),
                  )
              }
            _, ["sim", "chats", chat_id, "events"] -> {
              let after = query_after(req)
              let events =
                actor.call(store, waiting: 1000, sending: Get(_, chat_id, after))
              json_response(200, events_json(events))
            }
            _, _ ->
              json_response(
                404,
                json.object([#("error", json.string("not found"))]),
              )
          }
        }
      }
  }
}

fn handle_post(
  _req: request.Request(Connection),
  raw: String,
  store: Subject(StoreMessage),
  handler: port.ChannelHandler,
) -> response.Response(ResponseData) {
  case decode_message(raw) {
    Error(_) ->
      json_response(
        400,
        json.object([#("error", json.string("invalid message"))]),
      )
    Ok(input) -> {
      let message =
        port.ChannelMessage(
          id: "sim-" <> int.to_string(unique_id()),
          channel: "sim",
          channel_id: input.chat_id,
          user_id: input.user_id,
          username: input.username,
          content: input.content,
          is_bot: False,
          reply_to_id: None,
        )
      let events = process.new_subject()
      let turn_session = session.sim_session_id(input.chat_id, input.user_id)
      let result = handler(port.InboundMessage(message), events)
      let outcome = case result {
        Ok(port.ImmediateReply(reply)) -> {
          append_parts(store, reply)
          reply_outcome(reply.content)
        }
        Ok(port.StreamReply(base)) -> collect_stream(events, store, base)
        Error(port.Ignored(_)) -> "denied"
        Error(port.SendFailed(_)) -> "error"
        Error(_) -> "error"
      }
      append_turn_end(store, input.chat_id, turn_session, outcome)
      json_response(
        200,
        json.object([#("message_id", json.string(message.id))]),
      )
    }
  }
}

const stream_idle_timeout_ms = 60_000

/// A kernel refusal delivered as a normal reply is still a denied turn.
fn reply_outcome(content: String) -> String {
  let denied_reply = case closed_group_global.get_config() {
    Some(cfg) -> cfg.access.denied_reply
    None -> ""
  }
  case closed_group_pure.is_kernel_refusal(content, denied_reply) {
    True -> "denied"
    False -> "ok"
  }
}

fn collect_stream(
  events: Subject(port.ChannelStreamEvent),
  store: Subject(StoreMessage),
  base: port.ChannelReply,
) -> String {
  case process.receive(events, within: stream_idle_timeout_ms) {
    Ok(port.StreamUpdate(reply)) -> {
      append(store, reply)
      collect_stream(events, store, base)
    }
    Ok(port.StreamComplete(reply)) -> {
      append_parts(store, reply)
      reply_outcome(reply.content)
    }
    Ok(port.StreamFailure(_reason)) -> {
      append(store, port.ChannelReply(..base, content: "stream failed"))
      "error"
    }
    Error(_) -> {
      append(store, port.ChannelReply(..base, content: "stream timed out"))
      "error"
    }
  }
}

fn append_parts(store: Subject(StoreMessage), reply: port.ChannelReply) -> Nil {
  reply
  |> chunking.split_reply(4096)
  |> list.each(fn(part) { append(store, part) })
  Nil
}

fn authorized(req: request.Request(Connection), token: String) -> Bool {
  case list.key_find(req.headers, "authorization") {
    Ok(value) -> value == "Bearer " <> token
    Error(_) -> False
  }
}

fn request_path(req: request.Request(Connection)) -> List(String) {
  uri.path_segments(req.path)
}

fn query_after(req: request.Request(Connection)) -> Int {
  let params = case request.get_query(req) {
    Ok(params) -> params
    Error(_) -> []
  }
  case list.key_find(params, "after") {
    Ok(value) ->
      case int.parse(value) {
        Ok(n) -> n
        Error(_) -> 0
      }
    Error(_) -> 0
  }
}

type SimInput {
  SimInput(
    chat_id: String,
    user_id: String,
    username: String,
    content: String,
    is_group: Bool,
  )
}

fn decode_message(raw: String) -> Result(SimInput, Nil) {
  let decoder = {
    use chat_id <- decode.field("chat_id", decode.string)
    use user_id <- decode.field("user_id", decode.string)
    use username <- decode.optional_field("username", "", decode.string)
    use content <- decode.field("content", decode.string)
    use is_group <- decode.optional_field("is_group", False, decode.bool)
    decode.success(SimInput(chat_id, user_id, username, content, is_group))
  }
  case json.parse(from: raw, using: decoder) {
    Ok(value) ->
      case
        string.contains(value.chat_id, ":")
        || string.contains(value.user_id, ":")
      {
        True -> Error(Nil)
        False -> Ok(value)
      }
    Error(_) -> Error(Nil)
  }
}

fn events_json(events: List(SimEvent)) -> json.Json {
  json.object([
    #(
      "events",
      json.array(events, fn(event) {
        json.object([
          #("seq", json.int(event.seq)),
          #("type", json.string(event.kind)),
          #("content", json.string(event.content)),
          #("message_id", case event.message_id {
            Some(id) -> json.string(id)
            None -> json.null()
          }),
        ])
      }),
    ),
  ])
}

fn json_response(
  status: Int,
  body: json.Json,
) -> response.Response(ResponseData) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json.to_string(body))))
  |> response.set_header("content-type", "application/json")
}
