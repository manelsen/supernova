//// PRD-C, C-02: one webhook server for every channel that receives by
//// webhook. Each channel brings its route: how to verify, how to read.

import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit/should
import supernova/channel/port
import supernova/channel/webhook_server

fn message(id: String) -> port.ChannelInbound {
  port.InboundMessage(port.ChannelMessage(
    id: id,
    channel: "fake",
    channel_id: "c",
    user_id: "u",
    username: "U",
    content: "oi",
    is_bot: False,
    reply_to_id: None,
  ))
}

fn route(delivered: process.Subject(port.ChannelInbound)) {
  webhook_server.Route(
    channel: "fake",
    verify: fn(headers, _body) { list.contains(headers, #("x-token", "certo")) },
    translate: fn(body) {
      case body {
        <<"msg">> -> webhook_server.Deliver([message("1"), message("2")])
        <<"evento">> -> webhook_server.Handled
        _ -> webhook_server.Malformed
      }
    },
    dispatch: fn(inbound) { process.send(delivered, inbound) },
  )
}

fn drain(subject, acc) {
  case process.receive(subject, 0) {
    Ok(x) -> drain(subject, [x, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

pub fn a_verified_message_is_delivered_before_the_answer_test() {
  let delivered = process.new_subject()
  let routes = [route(delivered)]
  webhook_server.respond(
    routes,
    "POST",
    ["webhook", "fake"],
    [
      #("x-token", "certo"),
    ],
    <<"msg">>,
  )
  |> should.equal(200)
  drain(delivered, []) |> should.equal([message("1"), message("2")])
}

pub fn without_a_valid_signature_nothing_is_delivered_test() {
  let delivered = process.new_subject()
  webhook_server.respond(
    [route(delivered)],
    "POST",
    ["webhook", "fake"],
    [
      #("x-token", "errado"),
    ],
    <<"msg">>,
  )
  |> should.equal(401)
  drain(delivered, []) |> should.equal([])
}

pub fn other_paths_methods_and_bodies_test() {
  let delivered = process.new_subject()
  let routes = [route(delivered)]
  let ok = [#("x-token", "certo")]
  webhook_server.respond(routes, "POST", ["webhook", "outro"], ok, <<"msg">>)
  |> should.equal(404)
  webhook_server.respond(routes, "GET", ["webhook", "fake"], ok, <<"msg">>)
  |> should.equal(405)
  webhook_server.respond(routes, "POST", ["webhook", "fake"], ok, <<"lixo">>)
  |> should.equal(400)
  webhook_server.respond(routes, "POST", ["webhook", "fake"], ok, <<"evento">>)
  |> should.equal(200)
  drain(delivered, []) |> should.equal([])
}

pub fn hub_signature_test() {
  let body = <<"{\"event\":\"message\"}">>
  let signature = "sha256=" <> hmac_hex("segredo", body)
  webhook_server.hub_signature_valid("segredo", body, signature)
  |> should.be_true()
  webhook_server.hub_signature_valid("outro", body, signature)
  |> should.be_false()
  webhook_server.hub_signature_valid("segredo", <<"x">>, signature)
  |> should.be_false()
  webhook_server.hub_signature_valid("segredo", body, "sha256=00")
  |> should.be_false()
  webhook_server.hub_signature_valid("segredo", body, "")
  |> should.be_false()
  webhook_server.hub_signature_valid("", body, signature) |> should.be_false()
}

const test_port = 18_801

pub fn the_listener_serves_registered_routes_test() {
  let delivered = process.new_subject()
  webhook_server.register(route(delivered))
  let assert Ok(server) = webhook_server.start("127.0.0.1", test_port)
  post(test_port, "/webhook/fake", [#("x-token", "certo")], <<"msg">>).0
  |> should.equal(200)
  post(test_port, "/webhook/fake", [], <<"msg">>).0 |> should.equal(401)
  post(test_port, "/webhook/fake", [#("x-token", "certo")], <<
    0:size(8_400_000),
  >>).0
  |> should.equal(413)
  webhook_server.stop(server)
  webhook_server.unregister("fake")
  drain(delivered, []) |> should.equal([message("1"), message("2")])
}

@external(erlang, "webhook_test_ffi", "post")
fn post(
  port: Int,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> #(Int, BitArray)

@external(erlang, "webhook_test_ffi", "hmac_hex")
fn hmac_hex(secret: String, body: BitArray) -> String

pub fn the_instance_listener_starts_and_stops_test() {
  let assert Ok(Nil) = webhook_server.start_global("127.0.0.1", 18_802)
  post(18_802, "/webhook/ninguem", [], <<"x">>).0 |> should.equal(404)
  webhook_server.stop_global()
  webhook_server.stop_global()
  webhook_server.start("127.0.0.1", 18_802)
  |> should.be_ok
  |> webhook_server.stop
}
