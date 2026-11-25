//// The closed group's commands: one list for `/help` and for the Telegram
//// menu, by role, and every entry is a name Telegram accepts.

import e2e/e2e_support as support
import gleam/erlang/process
import gleam/int
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

// ============================================================================
// Suggestions (PRD-D, D-04)
// ============================================================================

fn sources() -> commands.Sources {
  commands.Sources(
    models: ["deepseek deepseek-chat", "gemini gemini-3.5-flash-lite"],
    agenda: [#(3, "tomar o remédio das oito"), #(7, "ligar para a irmã")],
    principals: ["discord:456", "telegram:9"],
  )
}

pub fn member_gets_no_admin_suggestions_test() {
  commands.suggest("acesso", "", False, sources()) |> should.equal([])
  commands.suggest("uso", "", False, sources()) |> should.equal([])
  commands.suggest("teto", "", False, sources()) |> should.equal([])
}

pub fn admin_sees_principals_after_remover_test() {
  commands.suggest("acesso", "remover d", True, sources())
  |> should.equal([#("remover discord:456", "remover discord:456")])
}

pub fn agenda_suggests_the_persons_entries_test() {
  let assert [#(label, value), _] =
    commands.suggest("agenda", "rem", False, sources())
  value |> should.equal("remover 3")
  label |> should.equal("remover 3 · tomar o remédio das oito")
}

pub fn suggestions_ignore_case_and_accents_test() {
  commands.suggest("esquecer", "CONFÍ", False, sources())
  |> should.equal([#("confirmo", "confirmo")])
}

pub fn model_suggestions_come_from_the_catalog_test() {
  commands.suggest("model", "gem", False, sources())
  |> should.equal([
    #("gemini gemini-3.5-flash-lite", "gemini gemini-3.5-flash-lite"),
  ])
}

pub fn unknown_command_has_no_suggestions_test() {
  commands.suggest("nada", "", True, sources()) |> should.equal([])
  commands.suggest("help", "", True, sources()) |> should.equal([])
}

pub fn suggestions_are_capped_at_25_test() {
  let many =
    commands.Sources(
      ..sources(),
      agenda: int.range(from: 1, to: 41, with: [], run: fn(acc, n) {
        [#(n, "tarefa"), ..acc]
      }),
    )
  commands.suggest("agenda", "", False, many) |> list.length |> should.equal(25)
}
