//// Tests for the Session Logger module.

import gleeunit/should
import supernova/core/session/logger

pub fn log_returns_entry_test() {
  let entry = logger.log("session_001", "info", "User sent message")

  entry.session_id
  |> should.equal("session_001")

  entry.level
  |> should.equal("info")

  entry.message
  |> should.equal("User sent message")
}

pub fn log_levels_test() {
  let debug = logger.log("s1", "debug", "debug msg")
  let info = logger.log("s1", "info", "info msg")
  let warn = logger.log("s1", "warn", "warn msg")
  let error = logger.log("s1", "error", "error msg")

  debug.level |> should.equal("debug")
  info.level |> should.equal("info")
  warn.level |> should.equal("warn")
  error.level |> should.equal("error")
}

pub fn format_entry_test() {
  let entry = logger.log("s1", "info", "hello")
  let formatted = logger.format(entry)

  formatted
  |> should.equal("[info] [session:s1] hello")
}
