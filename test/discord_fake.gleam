//// A local stand-in for the Discord gateway, for tests of the live client.
////
//// The WebSocket server (`discord_fake_ws_ffi.erl`) accepts any number of
//// connections and reports each one, every text frame the client sends,
//// and every close. The test answers with the frames Discord would send
//// (`hello`, `ready`, `dispatch`, …) and can close a connection with a
//// code, or drop it without a close frame.

import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/option.{type Option}
import gleam/string

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
