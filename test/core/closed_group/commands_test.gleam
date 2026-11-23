//// The closed group's commands: one list for `/help` and for the Telegram
//// menu, by role, and every entry is a name Telegram accepts.

import e2e/e2e_support as support
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import supernova/adapters/telegram
import supernova/channel/registry
import supernova/config
import supernova/core/closed_group/commands
import telegram_fake

pub fn members_do_not_see_admin_commands_test() {
  let member = commands.help_text(False)
  string.contains(member, "/agenda") |> should.equal(True)
  string.contains(member, "/esquecer confirmo") |> should.equal(True)
  string.contains(member, "/acesso") |> should.equal(False)
  string.contains(member, "/teto") |> should.equal(False)

  let admin = commands.help_text(True)
  string.contains(admin, "/agenda") |> should.equal(True)
  string.contains(admin, "Admin:") |> should.equal(True)
  string.contains(admin, "/acesso") |> should.equal(True)
  string.contains(admin, "/auditoria") |> should.equal(True)
}

pub fn help_no_longer_lists_what_does_not_exist_test() {
  let admin = commands.help_text(True)
  list.each(["/reasoning", "/commands", "/start", "Framework"], fn(gone) {
    string.contains(admin, gone) |> should.equal(False)
  })
}

pub fn every_command_is_a_valid_telegram_menu_entry_test() {
  list.each(commands.all, fn(command) {
    let valid_name =
      string.length(command.name) >= 1
      && string.length(command.name) <= 32
      && string.to_graphemes(command.name)
      |> list.all(fn(c) {
        string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", c)
      })
    valid_name |> should.equal(True)
    { string.length(command.description) >= 1 } |> should.equal(True)
    { string.length(command.description) <= 256 } |> should.equal(True)
  })
}

pub fn set_my_commands_sends_names_descriptions_and_scope_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  let api = telegram.with_base_url(telegram.new_config("t"), fake.base_url)
  let assert Ok(Nil) =
    telegram.set_my_commands(
      api,
      [#("agenda", "O que você pediu para depois")],
      telegram.ChatScope("42"),
      Some("pt"),
    )
  let assert Ok(recorded) = process.receive(requests, 2000)
  recorded.method |> should.equal("setMyCommands")
  string.contains(recorded.body, "\"command\":\"agenda\"") |> should.equal(True)
  string.contains(recorded.body, "\"type\":\"chat\"") |> should.equal(True)
  string.contains(recorded.body, "\"chat_id\":\"42\"") |> should.equal(True)
  string.contains(recorded.body, "\"language_code\":\"pt\"")
  |> should.equal(True)
}

/// In the closed group, /help answers with the closed group's commands.
pub fn help_in_the_closed_group_lists_its_commands_test() {
  let base = support.channel_config()
  let cfg =
    config.Config(..base, access: support.access_config([], ["telegram:123"]))
  support.with_runtime_root(cfg, fn(root) {
    support.seed_core(root, "telegram:123", "Núcleo de teste.")
    let recorder = process.new_subject()
    let channels =
      support.telegram_start_registry(
        support.channel_config(),
        support.telegram_handler(support.mock_config()),
        [support.telegram_update("123", "123", "/help")],
        recorder,
      )
    support.await_content(recorder, "/esquecer confirmo") |> should.equal(True)
    registry.stop_channels(channels)
  })
}
