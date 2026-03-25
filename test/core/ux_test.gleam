//// Tests for UX Help Text.

import gleam/string
import gleeunit/should
import supernova/core/ux

pub fn help_text_for_discord_test() {
  let text = ux.help_text("discord")

  string.contains(text, "Supernova")
  |> should.equal(True)

  string.contains(text, "/help")
  |> should.equal(True)
}

pub fn help_text_for_telegram_test() {
  let text = ux.help_text("telegram")

  string.contains(text, "Supernova")
  |> should.equal(True)

  string.contains(text, "/start")
  |> should.equal(True)
}

pub fn help_text_for_unknown_channel_test() {
  let text = ux.help_text("unknown")

  string.contains(text, "Supernova")
  |> should.equal(True)
}
