//// Private delivery, rate limits and mentions against the local API fake
//// (PRD-D, D-06).

import discord_fake
import e2e/e2e_support as support
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/adapters/discord_rest
import supernova/agenda/store
import supernova/agenda/sweeper
import supernova/channel/catalog
import supernova/channel/channel_kit
import supernova/channel/port
import supernova/channel/registry
import supernova/tools/agenda

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
      ),
    )
  channel_registry
}

fn reply(chat_id: String, content: String) -> port.ChannelReply {
  port.ChannelReply(
    channel_id: chat_id,
    content: content,
    reply_to_id: None,
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: None,
    media: [],
  )
}

pub fn private_chat_is_the_person_test() {
  catalog.get("discord").private_chat_for("456") |> should.equal("dm:456")
  catalog.get("discord").private_delivery |> should.be_true
  agenda.deliverable("discord:456") |> should.be_true
}

pub fn agenda_wakes_in_the_private_chat_of_the_channel_test() {
  let entry =
    store.Entry(id: 3, spec: "x", request: "y", created_at: 0, next_run_at: 0)
  sweeper.wake_message("discord:456", entry, 0).channel_id
  |> should.equal("dm:456")
  // Telegram keeps the user id as its private chat.
  sweeper.wake_message("telegram:123", entry, 0).channel_id
  |> should.equal("123")
}

pub fn a_private_reply_opens_the_dm_once_test() {
  let api = discord_fake.start_api()
  let channel_registry = start(api)

  let assert Ok(Nil) =
    registry.send(channel_registry, "discord", reply("dm:456", "oi"))
  let open = discord_fake.expect_request(api, "/users/@me/channels", 3000)
  string.contains(open.body, "\"recipient_id\":\"456\"") |> should.be_true
  let first = discord_fake.expect_request(api, "/channels/dm-", 3000)
  first.method |> should.equal("POST")

  // The DM channel is remembered: the second reply goes straight there.
  let assert Ok(Nil) =
    registry.send(channel_registry, "discord", reply("dm:456", "de novo"))
  let second = discord_fake.expect_request(api, "/", 3000)
  string.starts_with(second.path, "/channels/" <> channel_of(first.path))
  |> should.be_true
  registry.stop_channels(channel_registry)
}

fn channel_of(path: String) -> String {
  case string.split(path, "/") {
    ["", "channels", channel, ..] -> channel
    _ -> ""
  }
}

pub fn replies_never_ping_anyone_test() {
  let api = discord_fake.start_api()
  let channel_registry = start(api)
  let assert Ok(Nil) =
    registry.send(
      channel_registry,
      "discord",
      reply("chan1@guild:g1", "@everyone olhem"),
    )
  let sent = discord_fake.expect_request(api, "/channels/chan1/messages", 3000)
  string.contains(sent.body, "\"allowed_mentions\":{\"parse\":[]")
  |> should.be_true
  registry.stop_channels(channel_registry)
}

pub fn control_characters_keep_the_body_valid_json_test() {
  let api = discord_fake.start_api()
  let channel_registry = start(api)
  let content = "aspas \" barra \\ sino \u{0007} fim"
  let assert Ok(Nil) =
    registry.send(channel_registry, "discord", reply("chan1@guild:g1", content))
  let sent = discord_fake.expect_request(api, "/channels/chan1/messages", 3000)
  json.parse(sent.body, decode.at(["content"], decode.string))
  |> should.equal(Ok(content))
  registry.stop_channels(channel_registry)
}

pub fn rate_limit_waits_at_least_a_second_test() {
  let api = discord_fake.start_api()
  let channel_registry = start(api)
  discord_fake.script(
    api,
    "/channels/chan1/messages",
    429,
    "{\"message\":\"You are being rate limited.\",\"retry_after\":0.35,\"global\":false}",
  )
  registry.send(channel_registry, "discord", reply("chan1@guild:g1", "oi"))
  |> should.equal(Error(port.RateLimited(retry_after_seconds: 1)))
  registry.stop_channels(channel_registry)
}

pub fn retry_after_is_in_seconds_test() {
  discord_rest.extract_retry_after("{\"retry_after\":5}") |> should.equal(5000)
  discord_rest.extract_retry_after("{\"retry_after\":0.35}")
  |> should.equal(350)
  discord_rest.extract_retry_after("{\"retry_after\":1.0001}")
  |> should.equal(1001)
  discord_rest.extract_retry_after("{}") |> should.equal(5000)
}
