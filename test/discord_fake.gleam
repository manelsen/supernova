//// A local stand-in for the Discord gateway, for tests of the live client.
////
//// The WebSocket server (`discord_fake_ws_ffi.erl`) accepts any number of
//// connections and reports each one, every text frame the client sends,
//// and every close. The test answers with the frames Discord would send
//// (`hello`, `ready`, `dispatch`, …) and can close a connection with a
//// code, or drop it without a close frame.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string
import mist

pub type FakeEvent {
  Connected(Pid)
  Received(Pid, String)
  Closed(Pid)
}

pub type Fake {
  Fake(url: String, events: Subject(FakeEvent))
}

@external(erlang, "discord_fake_ws_ffi", "start")
fn start_ffi(events: Subject(FakeEvent)) -> Int

@external(erlang, "discord_fake_ws_ffi", "send_text")
pub fn send_text(connection: Pid, text: String) -> Nil

@external(erlang, "discord_fake_ws_ffi", "close")
pub fn close(connection: Pid, code: Int) -> Nil

@external(erlang, "discord_fake_ws_ffi", "drop")
pub fn drop(connection: Pid) -> Nil

/// Start the fake. Events go to a subject owned by the calling process.
pub fn start() -> Fake {
  let events = process.new_subject()
  let port = start_ffi(events)
  Fake(
    url: "ws://127.0.0.1:" <> int.to_string(port) <> "/?v=10&encoding=json",
    events: events,
  )
}

/// The base URL Discord would put in `resume_gateway_url`: no path, no
/// query.
pub fn resume_url(fake: Fake) -> String {
  case string.split_once(fake.url, "/?") {
    Ok(#(base, _)) -> base
    Error(_) -> fake.url
  }
}

/// The next new connection, within `within` ms.
pub fn expect_connection(fake: Fake, within: Int) -> Pid {
  case next(fake, within) {
    Ok(Connected(pid)) -> pid
    Ok(Received(_, _)) -> expect_connection(fake, within)
    Ok(Closed(_)) -> expect_connection(fake, within)
    Error(_) -> panic as "the client did not connect"
  }
}

/// The next frame the client sent, as `#(op, frame)`.
pub fn expect_frame(fake: Fake, within: Int) -> #(Int, String) {
  case next(fake, within) {
    Ok(Received(_, text)) -> #(opcode(text), text)
    Ok(_) -> expect_frame(fake, within)
    Error(_) -> panic as "the client sent no frame"
  }
}

/// The next frame with opcode `op`, skipping others (heartbeats).
pub fn expect_op(fake: Fake, op: Int, within: Int) -> String {
  let #(got, text) = expect_frame(fake, within)
  case got == op {
    True -> text
    False -> expect_op(fake, op, within)
  }
}

/// Nothing at all happens within `within` ms.
pub fn expect_quiet(fake: Fake, within: Int) -> Nil {
  case next(fake, within) {
    Error(_) -> Nil
    Ok(_) -> panic as "the fake was not quiet"
  }
}

/// The next close, skipping frames.
pub fn expect_closed(fake: Fake, within: Int) -> Pid {
  case next(fake, within) {
    Ok(Closed(pid)) -> pid
    Ok(_) -> expect_closed(fake, within)
    Error(_) -> panic as "no connection closed"
  }
}

fn next(fake: Fake, within: Int) -> Result(FakeEvent, Nil) {
  process.receive(fake.events, within)
}

pub fn opcode(frame: String) -> Int {
  case json.parse(frame, decode.at(["op"], decode.int)) {
    Ok(op) -> op
    Error(_) -> -1
  }
}

/// A string field inside `d`.
pub fn d_string(frame: String, field: String) -> Option(String) {
  json.parse(frame, decode.at(["d", field], decode.string))
  |> option.from_result
}

/// An int field inside `d`.
pub fn d_int(frame: String, field: String) -> Option(Int) {
  json.parse(frame, decode.at(["d", field], decode.int))
  |> option.from_result
}

pub fn hello(interval_ms: Int) -> String {
  "{\"op\":10,\"d\":{\"heartbeat_interval\":"
  <> int.to_string(interval_ms)
  <> "},\"s\":null,\"t\":null}"
}

pub fn heartbeat_ack() -> String {
  "{\"op\":11,\"d\":null}"
}

pub fn reconnect() -> String {
  "{\"op\":7,\"d\":null}"
}

pub fn invalid_session(resumable: Bool) -> String {
  case resumable {
    True -> "{\"op\":9,\"d\":true}"
    False -> "{\"op\":9,\"d\":false}"
  }
}

pub fn ready(session_id: String, resume_url: String, sequence: Int) -> String {
  dispatch(
    "READY",
    "{\"v\":10,\"session_id\":\""
      <> session_id
      <> "\",\"resume_gateway_url\":\""
      <> resume_url
      <> "\",\"user\":{\"id\":\"900000000000000001\",\"username\":\"supernova\",\"discriminator\":\"0\",\"bot\":true},\"guilds\":[{\"id\":\"900000000000000008\",\"unavailable\":true}]}",
    sequence,
  )
}

pub fn resumed(sequence: Int) -> String {
  dispatch("RESUMED", "null", sequence)
}

pub fn dispatch(event: String, d: String, sequence: Int) -> String {
  "{\"op\":0,\"t\":\""
  <> event
  <> "\",\"s\":"
  <> int.to_string(sequence)
  <> ",\"d\":"
  <> d
  <> "}"
}

// ============================================================================
// REST API fake
// ============================================================================

/// One request the API fake received.
pub type ApiRequest {
  ApiRequest(method: String, path: String, body: String)
}

pub type Api {
  Api(base_url: String, requests: Subject(ApiRequest), state: Subject(ApiMsg))
}

pub opaque type ApiMsg {
  Script(path_prefix: String, status: Int, body: String)
  Answer(request: ApiRequest, reply: Subject(#(Int, String)))
}

type ApiState {
  ApiState(scripts: List(#(String, Int, String)), next_id: Int)
}

/// Start the API fake. Every request is sent to `requests`, owned by the
/// calling process.
pub fn start_api() -> Api {
  let requests = process.new_subject()
  let assert Ok(started) =
    actor.new(ApiState([], 1000))
    |> actor.on_message(api_handle)
    |> actor.start
  let state = started.data
  let ports = process.new_subject()
  let assert Ok(_) =
    mist.new(fn(req) { api_serve(state, requests, req) })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
  let assert Ok(port) = process.receive(ports, 2000)
  Api(
    base_url: "http://127.0.0.1:" <> int.to_string(port),
    requests: requests,
    state: state,
  )
}

/// Answer the next request whose path starts with `path_prefix` with this
/// status and body.
pub fn script(api: Api, path_prefix: String, status: Int, body: String) -> Nil {
  process.send(api.state, Script(path_prefix, status, body))
}

/// The next request whose path starts with `path_prefix`, skipping others.
pub fn expect_request(
  api: Api,
  path_prefix: String,
  within: Int,
) -> ApiRequest {
  case process.receive(api.requests, within) {
    Ok(req) ->
      case string.starts_with(req.path, path_prefix) {
        True -> req
        False -> expect_request(api, path_prefix, within)
      }
    Error(_) -> panic as { "no request to " <> path_prefix }
  }
}

/// No request at all within `within` ms.
pub fn expect_no_request(api: Api, within: Int) -> Nil {
  case process.receive(api.requests, within) {
    Error(_) -> Nil
    Ok(req) -> panic as { "unexpected request to " <> req.path }
  }
}

fn api_serve(
  state: Subject(ApiMsg),
  requests: Subject(ApiRequest),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  let body = case mist.read_body(req, 10_000_000) {
    Ok(read) -> bit_array.to_string(read.body) |> result.unwrap("")
    Error(_) -> ""
  }
  let recorded =
    ApiRequest(method: http_method(req.method), path: req.path, body: body)
  process.send(requests, recorded)
  let #(status, answer) = process.call(state, 2000, Answer(recorded, _))
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(answer)))
}

fn http_method(method: http.Method) -> String {
  case method {
    http.Get -> "GET"
    http.Post -> "POST"
    http.Put -> "PUT"
    http.Patch -> "PATCH"
    http.Delete -> "DELETE"
    _ -> "OTHER"
  }
}

fn api_handle(state: ApiState, msg: ApiMsg) -> actor.Next(ApiState, ApiMsg) {
  case msg {
    Script(prefix, status, body) ->
      actor.continue(
        ApiState(
          ..state,
          scripts: list.append(state.scripts, [
            #(prefix, status, body),
          ]),
        ),
      )
    Answer(req, reply) -> {
      case take_script(state.scripts, req.path, []) {
        Ok(#(status, body, rest)) -> {
          process.send(reply, #(status, body))
          actor.continue(ApiState(..state, scripts: rest))
        }
        Error(_) -> {
          let id = state.next_id
          process.send(reply, default_answer(req, int.to_string(id)))
          actor.continue(ApiState(..state, next_id: id + 1))
        }
      }
    }
  }
}

fn take_script(
  scripts: List(#(String, Int, String)),
  path: String,
  skipped: List(#(String, Int, String)),
) -> Result(#(Int, String, List(#(String, Int, String))), Nil) {
  case scripts {
    [] -> Error(Nil)
    [#(prefix, status, body) as first, ..rest] ->
      case string.starts_with(path, prefix) {
        True -> Ok(#(status, body, list.append(list.reverse(skipped), rest)))
        False -> take_script(rest, path, [first, ..skipped])
      }
  }
}

/// What Discord answers when nothing is scripted.
fn default_answer(req: ApiRequest, id: String) -> #(Int, String) {
  case req.method, string.contains(req.path, "/callback") {
    "POST", True -> #(204, "")
    _, _ ->
      case req.method, req.path {
        "POST", "/users/@me/channels" -> #(
          200,
          "{\"id\":\"dm-" <> id <> "\",\"type\":1}",
        )
        "PUT", _ -> #(200, "[]")
        "POST", "/channels/" <> rest | "PATCH", "/channels/" <> rest ->
          case string.ends_with(rest, "/typing") {
            True -> #(204, "")
            False -> #(200, message_json(id, channel_of(rest)))
          }
        _, _ -> #(204, "")
      }
  }
}

fn channel_of(rest: String) -> String {
  case string.split(rest, "/") {
    [channel, ..] -> channel
    [] -> ""
  }
}

fn message_json(id: String, channel_id: String) -> String {
  "{\"id\":\""
  <> id
  <> "\",\"channel_id\":\""
  <> channel_id
  <> "\",\"content\":\"\",\"timestamp\":\"2026-11-25T00:00:00Z\",\"author\":{\"id\":\"900000000000000001\",\"username\":\"supernova\",\"bot\":true}}"
}
