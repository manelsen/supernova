//// Minimal HTTP client for the sim channel, used by the scenario engine.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string

pub type Event {
  Event(seq: Int, chat_id: String, kind: String, content: String)
}

pub fn send(
  port: Int,
  token: String,
  chat_id: String,
  user_id: String,
  username: String,
  content: String,
  is_group: Bool,
) -> Result(Nil, String) {
  let body =
    json.to_string(
      json.object([
        #("chat_id", json.string(chat_id)),
        #("user_id", json.string(user_id)),
        #("username", json.string(username)),
        #("content", json.string(content)),
        #("is_group", json.bool(is_group)),
      ]),
    )
  case http_post(port, "/sim/messages", token, body) {
    Ok(#(200, _)) -> Ok(Nil)
    Ok(#(status, _body)) ->
      Error("sim send failed with status " <> int.to_string(status))
    Error(_) -> Error("sim send failed")
  }
}

pub fn events(
  port: Int,
  token: String,
  chat_id: String,
  after: Int,
) -> Result(List(Event), String) {
  let path =
    "/sim/chats/" <> chat_id <> "/events?after=" <> int.to_string(after)
  case http_get(port, path, token) {
    Ok(#(200, body)) ->
      case json.parse(from: body, using: events_payload_decoder(chat_id)) {
        Ok(events) -> Ok(events)
        Error(_) -> Error("invalid sim events payload")
      }
    Ok(#(status, body)) ->
      Error(
        "sim events failed with status "
        <> int.to_string(status)
        <> ": "
        <> body,
      )
    Error(reason) ->
      Error("sim events request failed: " <> string.inspect(reason))
  }
}

fn events_payload_decoder(chat_id: String) -> decode.Decoder(List(Event)) {
  use events <- decode.field("events", decode.list(event_decoder(chat_id)))
  decode.success(events)
}

fn event_decoder(chat_id: String) -> decode.Decoder(Event) {
  use seq <- decode.field("seq", decode.int)
  use kind <- decode.field("type", decode.string)
  use content <- decode.field("content", decode.string)
  decode.success(Event(seq: seq, chat_id: chat_id, kind: kind, content: content))
}

pub type Turn {
  Turn(events: List(Event), last_seq: Int, outcome: String)
}

/// Poll until a `turn_end` for this chat appears after `after`.
pub fn await_turn(
  port: Int,
  token: String,
  chat_id: String,
  after: Int,
  timeout_ms: Int,
) -> Result(Turn, String) {
  await_turn_loop(port, token, chat_id, after, timeout_ms, [])
}

fn await_turn_loop(
  port: Int,
  token: String,
  chat_id: String,
  last_seq: Int,
  timeout_ms: Int,
  collected: List(Event),
) -> Result(Turn, String) {
  case events(port, token, chat_id, last_seq) {
    Error(reason) -> Error(reason)
    Ok(new_events) -> {
      let all = list.append(collected, new_events)
      let next_seq = case list.last(new_events) {
        Ok(event) -> event.seq
        Error(_) -> last_seq
      }
      case list.find(new_events, fn(event) { event.kind == "turn_end" }) {
        Ok(end) -> {
          let outcome = case
            json.parse(from: end.content, using: outcome_decoder())
          {
            Ok(value) -> value
            Error(_) -> "error"
          }
          Ok(Turn(
            events: final_output(all),
            last_seq: next_seq,
            outcome: outcome,
          ))
        }
        Error(_) -> {
          case timeout_ms <= 0 {
            True -> Error("turn timed out")
            False -> {
              sleeper(40)
              await_turn_loop(
                port,
                token,
                chat_id,
                next_seq,
                timeout_ms - 40,
                all,
              )
            }
          }
        }
      }
    }
  }
}

fn outcome_decoder() -> decode.Decoder(String) {
  use outcome <- decode.field("outcome", decode.string)
  decode.success(outcome)
}

fn final_output(events: List(Event)) -> List(Event) {
  let candidates =
    list.filter(events, fn(event) {
      event.kind != "turn_end" && string.trim(event.content) != ""
    })
  case list.last(candidates) {
    Ok(event) -> [event]
    Error(_) -> []
  }
}

@external(erlang, "supernova_harness_ffi", "http_post")
fn http_post(
  port: Int,
  path: String,
  token: String,
  body: String,
) -> Result(#(Int, String), Nil)

@external(erlang, "supernova_harness_ffi", "http_get")
fn http_get(
  port: Int,
  path: String,
  token: String,
) -> Result(#(Int, String), Nil)

@external(erlang, "timer", "sleep")
fn sleeper(ms: Int) -> Nil
