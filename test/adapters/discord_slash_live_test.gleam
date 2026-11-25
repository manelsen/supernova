//// Slash commands and autocomplete against the local fakes (PRD-D, D-04).

import discord_fake
import e2e/e2e_support as support
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/discord_channel
import supernova/adapters/discord_rest
import supernova/channel/channel_kit
import supernova/channel/port
import supernova/channel/registry
import supernova/config

fn with_discord(
  app_id: option.Option(String),
  guild_id: option.Option(String),
) -> config.Config {
  let base = support.channel_config()
  config.Config(
    ..base,
    discord: config.DiscordConfig(
      ..base.discord,
      app_id: app_id,
      guild_id: guild_id,
    ),
    access: support.access_config(["discord:1"], ["discord:456"]),
  )
}

fn ignore_all() -> port.ChannelHandler {
  fn(_inbound, _events) { Error(port.Ignored("test")) }
}

fn start(
  cfg: config.Config,
) -> #(registry.ChannelRegistry, discord_fake.Api, process.Pid) {
  let fake = discord_fake.start()
  let api = discord_fake.start_api()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      cfg,
      ignore_all(),
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
  #(channel_registry, api, conn)
}

fn autocomplete(user_id: String, command: String, typed: String) -> String {
  "{\"id\":\"ac-1\",\"application_id\":\"app-1\",\"type\":4,\"token\":\"tok-ac\",\"version\":1,\"channel_id\":\"dm1\",\"user\":{\"id\":\""
  <> user_id
  <> "\",\"username\":\"u\"},\"data\":{\"id\":\"cmd\",\"name\":\""
  <> command
  <> "\",\"type\":1,\"options\":[{\"name\":\"args\",\"type\":3,\"value\":\""
  <> typed
  <> "\",\"focused\":true}]}}"
}

pub fn ready_registers_member_commands_globally_test() {
  let #(channel_registry, api, _conn) = start(with_discord(Some("app-9"), None))
  let put =
    discord_fake.expect_request(api, "/applications/app-9/commands", 3000)
  put.method |> should.equal("PUT")
  string.contains(put.body, "\"name\":\"agenda\"") |> should.be_true
  string.contains(put.body, "\"autocomplete\":true") |> should.be_true
  // Admin commands are typed, not registered.
  string.contains(put.body, "\"name\":\"acesso\"") |> should.be_false
  registry.stop_channels(channel_registry)
}

pub fn configured_server_gets_an_empty_list_test() {
  let #(channel_registry, api, _conn) =
    start(with_discord(Some("app-9"), Some("g-1")))
  let put =
    discord_fake.expect_request(
      api,
      "/applications/app-9/guilds/g-1/commands",
      3000,
    )
  put.body |> should.equal("[]")
  registry.stop_channels(channel_registry)
}

pub fn application_id_falls_back_to_the_bot_user_test() {
  let #(channel_registry, api, _conn) = start(with_discord(None, None))
  let _ =
    discord_fake.expect_request(
      api,
      "/applications/900000000000000001/commands",
      3000,
    )
  registry.stop_channels(channel_registry)
}

pub fn autocomplete_follows_the_role_test() {
  let cfg = with_discord(Some("app-9"), None)
  support.with_runtime(cfg, fn() {
    let #(channel_registry, api, conn) = start(cfg)

    // The admin sees the principals.
    discord_fake.send_text(
      conn,
      discord_fake.dispatch(
        "INTERACTION_CREATE",
        autocomplete("1", "acesso", "rem"),
        2,
      ),
    )
    let admin =
      discord_fake.expect_request(
        api,
        "/interactions/ac-1/tok-ac/callback",
        3000,
      )
    string.contains(admin.body, "\"type\":8") |> should.be_true
    string.contains(admin.body, "remover discord:456") |> should.be_true

    // A member gets nothing for an admin command.
    discord_fake.send_text(
      conn,
      discord_fake.dispatch(
        "INTERACTION_CREATE",
        autocomplete("456", "acesso", ""),
        3,
      ),
    )
    let member =
      discord_fake.expect_request(
        api,
        "/interactions/ac-1/tok-ac/callback",
        3000,
      )
    string.contains(member.body, "\"choices\":[]") |> should.be_true

    // ...but gets the member suggestions.
    discord_fake.send_text(
      conn,
      discord_fake.dispatch(
        "INTERACTION_CREATE",
        autocomplete("456", "esquecer", "con"),
        4,
      ),
    )
    let forget =
      discord_fake.expect_request(
        api,
        "/interactions/ac-1/tok-ac/callback",
        3000,
      )
    string.contains(forget.body, "confirmo") |> should.be_true

    // Someone without access gets nothing at all.
    discord_fake.send_text(
      conn,
      discord_fake.dispatch(
        "INTERACTION_CREATE",
        autocomplete("999", "esquecer", ""),
        5,
      ),
    )
    let stranger =
      discord_fake.expect_request(
        api,
        "/interactions/ac-1/tok-ac/callback",
        3000,
      )
    string.contains(stranger.body, "\"choices\":[]") |> should.be_true
    registry.stop_channels(channel_registry)
  })
}

pub fn every_member_command_is_valid_for_discord_test() {
  discord_channel.slash_commands()
  |> list.all(discord_rest.valid_slash_command)
  |> should.be_true
}

pub fn invalid_slash_commands_test() {
  let valid = fn(name, description) {
    discord_rest.valid_slash_command(discord_rest.SlashCommand(
      name,
      description,
      False,
    ))
  }
  valid("Agenda", "x") |> should.be_false
  valid("com espaço", "x") |> should.be_false
  valid("ok", "") |> should.be_false
  valid("ok", string.repeat("a", 101)) |> should.be_false
  valid("agenda_2-x", "ok") |> should.be_true
}

pub fn autocomplete_response_caps_choices_test() {
  let body =
    int.range(from: 0, to: 30, with: [], run: fn(acc, n) { [n, ..acc] })
    |> list.reverse
    |> list.map(fn(n) { #(int.to_string(n), int.to_string(n)) })
    |> discord_rest.autocomplete_response
  string.contains(body, "\"value\":\"24\"") |> should.be_true
  string.contains(body, "\"value\":\"25\"") |> should.be_false
}
