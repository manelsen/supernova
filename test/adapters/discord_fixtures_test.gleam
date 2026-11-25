//// The real gateway captures of 27/02/2026 (test/fixtures/discord/,
//// anonymized) through the decoders of PRD-D: every frame of the kinds the
//// Supernova reads must parse, extra undocumented fields included.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import gleeunit/should
import supernova/adapters/discord_channel
import supernova/adapters/discord_events as events
import supernova/adapters/discord_gateway as gateway

type Frame {
  Frame(event: String, d: String, whole: String)
}

fn frames(name: String) -> List(Frame) {
  let assert Ok(body) = read_file("test/fixtures/discord/" <> name <> ".json")
  let frame = {
    use t <- decode.optional_field(
      "t",
      "",
      decode.one_of(decode.string, [decode.success("")]),
    )
    use d <- decode.field("d", decode.dynamic)
    use whole <- decode.then(decode.dynamic)
    decode.success(Frame(event: t, d: encode(d), whole: encode(whole)))
  }
  let assert Ok(list) = json.parse(body, decode.list(frame))
  should.be_true(list != [])
  list
}

pub fn every_captured_message_parses_test() {
  frames("gateway_message_create")
  |> list.each(fn(frame) {
    let assert events.EventMessageCreate(message) =
      events.parse_event("MESSAGE_CREATE", frame.d)
    should.be_true(message.id != "")
    should.be_true(message.author.id != "")
  })
}

pub fn every_captured_interaction_parses_and_gets_an_answer_test() {
  frames("gateway_interaction_create")
  |> list.each(fn(frame) {
    let assert events.EventInteractionCreate(interaction) =
      events.parse_event("INTERACTION_CREATE", frame.d)
    should.be_true(interaction.token != "")
    case interaction.interaction_type {
      events.MessageComponent | events.ApplicationCommand ->
        discord_channel.interaction_answer(interaction)
        |> option.is_some
        |> should.be_true
      _ -> Nil
    }
  })
}

pub fn captured_updates_deletes_and_reactions_parse_test() {
  [
    #("gateway_message_update", "MESSAGE_UPDATE"),
    #("gateway_message_delete", "MESSAGE_DELETE"),
    #("gateway_message_reaction_add", "MESSAGE_REACTION_ADD"),
  ]
  |> list.each(fn(pair) {
    frames(pair.0)
    |> list.each(fn(frame) {
      case events.parse_event(pair.1, frame.d) {
        events.EventUnknown(_, _) -> panic as { pair.0 <> " did not parse" }
        _ -> Nil
      }
    })
  })
}

pub fn captured_hello_and_ready_drive_the_gateway_test() {
  let assert Ok(gw) = gateway.start(gateway.default_config("t"))
  let subscriber = process.new_subject()
  let _ = gateway.subscribe(gw, subscriber)
  let assert [hello, ..] = frames("gateway_hello")
  process.send(gw, gateway.WsMessage(hello.whole))
  gateway.get_status(gw) |> should.equal(gateway.Identifying)

  let assert [ready, ..] = frames("gateway_ready")
  process.send(gw, gateway.WsMessage(ready.whole))
  gateway.get_status(gw) |> should.equal(gateway.Connected)
  let assert Ok(gateway.Ready(data)) = process.receive(subscriber, 1000)
  should.be_true(data.session_id != "")
  gateway.get_session_info(gw) |> option.is_some |> should.be_true
  gateway.stop(gw)
}

@external(erlang, "supernova_discord_ffi", "encode_json")
fn encode(term: dynamic.Dynamic) -> String

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)
