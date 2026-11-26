//// Streaming, buttons and send errors through the REST client, against the
//// local API fake (PRD-D, D-07: coverage of the live paths).

import aprovacao_amostra
import discord_fake
import e2e/e2e_support as support
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/channel/channel_kit
import supernova/channel/port
import supernova/channel/registry

fn start(api: discord_fake.Api) -> registry.ChannelRegistry {
  let fake = discord_fake.start()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      support.channel_config(),
      fn(_inbound, _events) { Error(port.Ignored("test")) },
      channel_kit.StartHooks(
        ..channel_kit.no_start_hooks(),
        discord_gateway: channel_kit.DiscordGatewayAt(
          gateway_url: fake.url,
          api_url: api.base_url,
        ),
        disable_telegram_polling: True,
        typing_keepalive_ms: 50,
      ),
    )
  channel_registry
}

fn reply(content: String) -> port.ChannelReply {
  port.ChannelReply(
    channel_id: "chan1@guild:g1",
    content: content,
    reply_to_id: None,
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: None,
    media: [],
  )
}

pub fn a_stream_edits_its_placeholder_until_done_test() {
  let api = discord_fake.start_api()
  let channel_registry = start(api)
  let events = process.new_subject()
  process.send(events, port.StreamUpdate(reply("Olá")))
  process.send(events, port.StreamComplete(reply("Olá, tudo bem?")))

  let assert Ok(Nil) =
    registry.send_stream(channel_registry, "discord", reply(""), events)
  let placeholder =
    discord_fake.expect_request(api, "/channels/chan1/messages", 3000)
  placeholder.method |> should.equal("POST")
  string.contains(placeholder.body, "Thinking...") |> should.be_true
  let update =
    discord_fake.expect_request(api, "/channels/chan1/messages/", 3000)
  update.method |> should.equal("PATCH")
  string.contains(update.body, "Olá") |> should.be_true
  let done = discord_fake.expect_request(api, "/channels/chan1/messages/", 3000)
  string.contains(done.body, "tudo bem?") |> should.be_true
  registry.stop_channels(channel_registry)
}

pub fn a_quiet_stream_keeps_typing_test() {
  let api = discord_fake.start_api()
  let channel_registry = start(api)
  let events = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.sleep(200)
      process.send(events, port.StreamComplete(reply("pronto")))
    })
  let assert Ok(Nil) =
    registry.send_stream(channel_registry, "discord", reply(""), events)
  let _ = discord_fake.expect_request(api, "/channels/chan1/typing", 3000)
  registry.stop_channels(channel_registry)
}

pub fn a_failed_stream_is_reported_test() {
  let api = discord_fake.start_api()
  let channel_registry = start(api)
  let events = process.new_subject()
  process.send(events, port.StreamFailure(port.SendFailed("modelo caiu")))
  registry.send_stream(channel_registry, "discord", reply(""), events)
  |> should.equal(Error(port.SendFailed("modelo caiu")))
  registry.stop_channels(channel_registry)
}

pub fn buttons_and_menus_become_components_test() {
  let api = discord_fake.start_api()
  let channel_registry = start(api)
  let interactive =
    port.ChannelInteractiveReply(blocks: [
      port.InteractionText("Escolha"),
      port.InteractionButtons([
        port.ChannelButton("Sim", "sim", port.ButtonPrimary),
        port.ChannelButton("Não", "nao", port.ButtonDanger),
        port.ChannelButton("Talvez", "talvez", port.ButtonSecondary),
        port.ChannelButton("Ok", "ok", port.ButtonSuccess),
      ]),
      port.InteractionSelect("modelo", Some("Modelo"), [
        port.ChannelSelectOption("DeepSeek", "deepseek"),
      ]),
    ])
  let assert Ok(Nil) =
    registry.send(
      channel_registry,
      "discord",
      port.ChannelReply(
        ..reply("Qual?"),
        interactive: Some(interactive),
        reply_to_id: Some("m0"),
        typing: True,
      ),
    )
  let _ = discord_fake.expect_request(api, "/channels/chan1/typing", 3000)
  let sent = discord_fake.expect_request(api, "/channels/chan1/messages", 3000)
  string.contains(sent.body, "\"custom_id\":\"sim\"") |> should.be_true
  string.contains(sent.body, "\"custom_id\":\"modelo\"") |> should.be_true
  string.contains(sent.body, "\"message_id\":\"m0\"") |> should.be_true
  registry.stop_channels(channel_registry)
}

/// PRD-K, K-02: a request for approval reaches Discord as three buttons.
pub fn approval_buttons_reach_discord_test() {
  let api = discord_fake.start_api()
  let channel_registry = start(api)
  let assert Ok(Nil) =
    registry.send(
      channel_registry,
      "discord",
      aprovacao_amostra.reply("chan1@guild:g1", 7),
    )
  let sent = discord_fake.expect_request(api, "/channels/chan1/messages", 3000)
  string.contains(sent.body, "\"custom_id\":\"aprovacao:7:sim\"")
  |> should.be_true
  string.contains(sent.body, "\"custom_id\":\"aprovacao:7:nao\"")
  |> should.be_true
  string.contains(sent.body, "\"custom_id\":\"aprovacao:7:sempre\"")
  |> should.be_true
  registry.stop_channels(channel_registry)
}

pub fn send_errors_map_to_channel_errors_test() {
  let api = discord_fake.start_api()
  let channel_registry = start(api)
  let attempt = fn(status, body) {
    discord_fake.script(api, "/channels/chan1/messages", status, body)
    registry.send(channel_registry, "discord", reply("oi"))
  }
  attempt(401, "{\"message\":\"401: Unauthorized\"}")
  |> should.equal(Error(port.NotConnected))
  let assert Error(port.SendFailed(_)) =
    attempt(403, "{\"message\":\"Missing Permissions\"}")
  let assert Error(port.SendFailed(_)) =
    attempt(404, "{\"message\":\"Unknown Channel\"}")
  let assert Error(port.SendFailed(_)) =
    attempt(500, "{\"message\":\"Internal\"}")
  let assert Error(port.SendFailed(_)) = attempt(400, "{\"message\":\"Bad\"}")
  registry.stop_channels(channel_registry)
}
