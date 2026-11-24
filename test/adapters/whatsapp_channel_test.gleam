//// PRD-C, C-04 end to end against a fake GOWA: a signed webhook reaches the
//// agent, the reply leaves through the REST API with basic auth, an
//// unsigned one is refused, an unknown LID in a group is asked to write in
//// private, a lost account is reported, and a LID seen with a phone is
//// learned.

import gleam/erlang/process
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import gowa_fake
import supernova/adapters/whatsapp_adapter
import supernova/channel/channel_kit
import supernova/channel/port
import supernova/channel/webhook_server
import supernova/core/identity/aliases
import test_workspace

const webhook_port = 18_805

const secret = "segredo-do-teste"

const agent = "628987654321@s.whatsapp.net"

fn signed(body: String) -> List(#(String, String)) {
  [
    #(
      "x-hub-signature-256",
      "sha256=" <> hmac_hex(secret, bit_array_from(body)),
    ),
  ]
}

fn message(fields: String) -> String {
  "{\"event\":\"message\",\"device_id\":\""
  <> agent
  <> "\",\"payload\":{\"id\":\"M1\",\"is_from_me\":false,"
  <> fields
  <> "}}"
}

pub fn whatsapp_end_to_end_test() {
  let dir = test_workspace.create_temp_dir("wa-e2e")
  let sent = process.new_subject()
  let bridge = gowa_fake.start(sent)
  let downs = process.new_subject()
  let seen = process.new_subject()
  let handler = fn(inbound, _events) {
    process.send(seen, inbound)
    case inbound {
      port.InboundMessage(msg) ->
        Ok(
          port.ImmediateReply(port.reply(
            to: msg,
            content: "olá, " <> msg.user_id,
          )),
        )
      _ -> Error(port.Ignored("no"))
    }
  }
  let assert Ok(adapter) =
    whatsapp_adapter.start(
      whatsapp_adapter.Settings(
        bridge_url: bridge,
        device_id: Some(agent),
        basic_auth: "supernova:senha",
        webhook_secret: secret,
        data_dir: dir,
      ),
      handler,
      channel_kit.no_start_hooks(),
      fn(reason) { process.send(downs, reason) },
    )
  let assert Ok(server) = webhook_server.start("127.0.0.1", webhook_port)

  // A signed private message: answered through GOWA with basic auth.
  let body =
    message(
      "\"chat_id\":\"628123456789@s.whatsapp.net\",\"from\":\"628123456789@s.whatsapp.net\",\"from_lid\":\"777@lid\",\"body\":\"oi\"",
    )
  post(webhook_port, "/webhook/whatsapp", signed(body), bit_array_from(body)).0
  |> should.equal(200)
  let assert Ok(port.InboundMessage(msg)) = process.receive(seen, 2000)
  msg.user_id |> should.equal("628123456789")
  let assert Ok(out) = process.receive(sent, 5000)
  out.path |> should.equal("/send/message")
  out.authorization |> should.equal("Basic c3VwZXJub3ZhOnNlbmhh")
  out.device |> should.equal(agent)
  string.contains(out.body, "\"phone\":\"628123456789@s.whatsapp.net\"")
  |> should.be_true()
  string.contains(out.body, "olá, 628123456789") |> should.be_true()
  // The LID that came along is now the same person.
  aliases.resolve("whatsapp:777@lid") |> should.equal("whatsapp:628123456789")

  // Unsigned: refused, nothing reaches the agent.
  post(webhook_port, "/webhook/whatsapp", [], bit_array_from(body)).0
  |> should.equal(401)
  process.receive(seen, 100) |> should.equal(Error(Nil))

  // An unknown LID calls the agent in a group: asked to write in private.
  let group =
    message(
      "\"chat_id\":\"1203630@g.us\",\"from\":\"555@lid\",\"body\":\"/eu\"",
    )
  post(webhook_port, "/webhook/whatsapp", signed(group), bit_array_from(group)).0
  |> should.equal(200)
  let assert Ok(ask) = process.receive(sent, 5000)
  string.contains(ask.body, "Me chama no privado") |> should.be_true()
  string.contains(ask.body, "\"phone\":\"1203630@g.us\"") |> should.be_true()
  process.receive(seen, 100) |> should.equal(Error(Nil))

  // A lost account is reported.
  let down =
    "{\"event\":\"device.logged_out\",\"device_id\":\""
    <> agent
    <> "\",\"payload\":{\"code\":401,\"reason\":\"logged out from another device\"}}"
  post(webhook_port, "/webhook/whatsapp", signed(down), bit_array_from(down)).0
  |> should.equal(200)
  let assert Ok(reason) = process.receive(downs, 1000)
  string.contains(reason, "desconectada") |> should.be_true()

  webhook_server.stop(server)
  adapter.stop()
  let assert Ok(Nil) = aliases.unlink(dir, "whatsapp:777@lid")
  test_workspace.remove_dir_recursive(dir)
  Nil
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

fn bit_array_from(text: String) -> BitArray {
  <<text:utf8>>
}
