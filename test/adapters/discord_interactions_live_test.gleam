//// Interactions and REST against the local fakes (PRD-D, D-03): Discord is
//// answered before the turn, a slash command is echoed, and the answer to a
//// button edits the message that held it.

import discord_fake
import e2e/e2e_support as support
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/discord_channel
import supernova/adapters/discord_events as events
import supernova/adapters/discord_rest
import supernova/channel/channel_kit
import supernova/channel/port
import supernova/channel/registry
import supernova/config

fn discord_config() -> config.Config {
  support.channel_config()
}

/// The channel connected to both fakes, with no recorder: every send goes
/// through the REST client to the API fake.
fn start(
  handler: port.ChannelHandler,
) -> #(
  registry.ChannelRegistry,
  discord_fake.Fake,
  discord_fake.Api,
  process.Pid,
) {
  let fake = discord_fake.start()
  let api = discord_fake.start_api()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      discord_config(),
      handler,
      channel_kit.StartHooks(
        ..channel_kit.no_start_hooks(),
        discord_gateway: channel_kit.DiscordGatewayAt(
          gateway_url: fake.url,
          api_url: api.base_url,
        ),
        disable_telegram_polling: True,
      ),
    )
  let conn = discord_fake.expect_connection(fake, 3000)
  discord_fake.send_text(conn, discord_fake.hello(60_000))
  let _ = discord_fake.expect_op(fake, 2, 3000)
  discord_fake.send_text(
    conn,
    discord_fake.ready("sess-1", discord_fake.resume_url(fake), 1),
  )
  #(channel_registry, fake, api, conn)
}

fn slow_handler(
  delay_ms: Int,
  reply: fn(port.ChannelInbound) -> port.ChannelReply,
) -> port.ChannelHandler {
  fn(inbound, _events) {
    process.sleep(delay_ms)
    Ok(port.ImmediateReply(reply(inbound)))
  }
}

fn button_press(custom_id: String, source_message_id: String) -> String {
  "{\"id\":\"inter-1\",\"application_id\":\"app-1\",\"type\":3,\"token\":\"tok-1\",\"version\":1,\"channel_id\":\"dm1\",\"user\":{\"id\":\"456\",\"username\":\"tester\"},\"message\":{\"id\":\""
  <> source_message_id
  <> "\"},\"data\":{\"custom_id\":\""
  <> custom_id
  <> "\",\"component_type\":2}}"
}

fn slash_command(name: String, args: String) -> String {
  "{\"id\":\"inter-2\",\"application_id\":\"app-1\",\"type\":2,\"token\":\"tok-2\",\"version\":1,\"channel_id\":\"dm1\",\"user\":{\"id\":\"456\",\"username\":\"tester\"},\"data\":{\"id\":\"cmd-1\",\"name\":\""
  <> name
  <> "\",\"type\":1,\"options\":[{\"name\":\"args\",\"type\":3,\"value\":\""
  <> args
  <> "\"}]}}"
}

pub fn button_is_acknowledged_before_the_turn_ends_test() {
  let #(channel_registry, _fake, api, conn) =
    start(
      slow_handler(2000, fn(_) {
        port.ChannelReply(
          channel_id: "dm:dm1",
          content: "feito",
          reply_to_id: None,
          thread_id: None,
          typing: False,
          edit_message_id: None,
          interactive: None,
          media: [],
        )
      }),
    )
  discord_fake.send_text(
    conn,
    discord_fake.dispatch("INTERACTION_CREATE", button_press("m:x", "src-1"), 2),
  )
  // Well before the 2 s turn: Discord's limit is 3 s.
  let ack =
    discord_fake.expect_request(
      api,
      "/interactions/inter-1/tok-1/callback",
      1000,
    )
  ack.method |> should.equal("POST")
  ack.body |> should.equal("{\"type\":6}")
  registry.stop_channels(channel_registry)
}

pub fn answer_to_a_button_edits_its_message_test() {
  let #(channel_registry, _fake, api, conn) =
    start(
      slow_handler(0, fn(inbound) {
        let assert port.InboundInteraction(interaction) = inbound
        port.ChannelReply(
          channel_id: interaction.channel_id,
          content: "modelo trocado",
          reply_to_id: None,
          thread_id: None,
          typing: False,
          edit_message_id: interaction.event.source_message_id,
          interactive: None,
          media: [],
        )
      }),
    )
  discord_fake.send_text(
    conn,
    discord_fake.dispatch("INTERACTION_CREATE", button_press("m:x", "src-9"), 2),
  )
  let edit =
    discord_fake.expect_request(api, "/channels/dm1/messages/src-9", 3000)
  edit.method |> should.equal("PATCH")
  string.contains(edit.body, "modelo trocado") |> should.be_true
  registry.stop_channels(channel_registry)
}

pub fn slash_command_is_echoed_and_reaches_the_core_as_text_test() {
  let seen = process.new_subject()
  let #(channel_registry, _fake, api, conn) =
    start(fn(inbound, _events) {
      let assert port.InboundMessage(message) = inbound
      process.send(seen, message.content)
      Error(port.Ignored("test"))
    })
  discord_fake.send_text(
    conn,
    discord_fake.dispatch(
      "INTERACTION_CREATE",
      slash_command("agenda", "remover 3"),
      2,
    ),
  )
  let ack =
    discord_fake.expect_request(
      api,
      "/interactions/inter-2/tok-2/callback",
      2000,
    )
  string.contains(ack.body, "\"type\":4") |> should.be_true
  string.contains(ack.body, "\"parse\":[]") |> should.be_true
  let assert Ok(content) = process.receive(seen, 2000)
  content |> should.equal("/agenda args:remover 3")
  registry.stop_channels(channel_registry)
}

pub fn rest_send_reaches_the_api_test() {
  let api = discord_fake.start_api()
  let assert Ok(client) =
    discord_rest.start(
      discord_rest.new_config("t") |> discord_rest.with_base_url(api.base_url),
    )
  let assert Ok(sent) = discord_rest.send_message(client, "chan-1", "oi")
  let req = discord_fake.expect_request(api, "/channels/chan-1/messages", 1000)
  req.method |> should.equal("POST")
  string.contains(req.body, "\"content\":\"oi\"") |> should.be_true
  sent.channel_id |> should.equal("chan-1")
  discord_rest.stop(client)
}

pub fn interaction_answer_by_kind_test() {
  let base =
    events.Interaction(
      id: "i",
      application_id: "a",
      interaction_type: events.MessageComponent,
      data: None,
      guild_id: None,
      channel_id: Some("c"),
      member: None,
      user: None,
      token: "t",
      version: 1,
      app_permissions: None,
      locale: None,
      guild_locale: None,
      message_id: Some("m"),
    )
  discord_channel.interaction_answer(base) |> should.equal(Some("{\"type\":6}"))

  let command =
    events.Interaction(
      ..base,
      interaction_type: events.ApplicationCommand,
      data: Some(events.ApplicationCommandData(
        id: "c",
        name: "uso",
        command_type: events.ChatInput,
        options: [],
        resolved: None,
        target_id: None,
      )),
    )
  let assert Some(echoed) = discord_channel.interaction_answer(command)
  string.contains(echoed, "\"content\":\"/uso\"") |> should.be_true

  events.Interaction(..base, interaction_type: events.Ping)
  |> discord_channel.interaction_answer
  |> should.equal(None)
}

/// The real create-message response (fixture of 27/02/2026) has no
/// `guild_id`: every send used to fail on it.
pub fn real_create_message_response_parses_test() {
  let assert Ok(body) =
    read_file("test/fixtures/discord/rest_create_message.json")
  let assert Ok(first) = json.parse(body, decode.at([0], decode.dynamic))
  let assert Ok(sent) = discord_rest.parse_sent_message(json_encode(first))
  sent.id |> should.equal("900000000000000019")
  sent.guild_id |> should.equal(None)
}

@external(erlang, "supernova_discord_ffi", "encode_json")
fn json_encode(term: dynamic.Dynamic) -> String

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)
