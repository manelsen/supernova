//// PRD-I, I-02 (D3): a link code is made in a private chat of someone who
//// already has access, has six unambiguous characters, lasts ten minutes,
//// is used once, and an identity gets five wrong tries an hour.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/core/identity/linking

pub fn commands_are_parsed_test() {
  linking.parse("/vincular") |> should.equal(Some(linking.Issue))
  linking.parse("  /vincular  ") |> should.equal(Some(linking.Issue))
  linking.parse("/vincular 4f7k2x")
  |> should.equal(Some(linking.Redeem("4F7K2X")))
  linking.parse("/desvincular") |> should.equal(Some(linking.Unlink(None)))
  linking.parse("/desvincular whatsapp:55")
  |> should.equal(Some(linking.Unlink(Some("whatsapp:55"))))
  linking.parse("vamos vincular") |> should.equal(None)
  linking.parse("/vinculo") |> should.equal(None)
}

pub fn codes_have_six_unambiguous_characters_test() {
  list.repeat(Nil, 50)
  |> list.index_map(fn(_, i) { i })
  |> list.each(fn(i) {
    let code = linking.issue("telegram:i02-shape-" <> string.inspect(i), 0)
    string.length(code) |> should.equal(6)
    string.to_graphemes(code)
    |> list.all(fn(c) { string.contains("ABCDEFGHJKLMNPQRSTUVWXYZ23456789", c) })
    |> should.be_true()
  })
}

pub fn a_code_is_used_once_test() {
  let code = linking.issue("telegram:i02-once", 1000)
  linking.redeem("whatsapp:i02-once", code, 2000)
  |> should.equal(Ok("telegram:i02-once"))
  linking.redeem("whatsapp:i02-once-b", code, 3000)
  |> should.equal(Error(linking.InvalidCode))
}

pub fn a_code_lasts_ten_minutes_test() {
  let code = linking.issue("telegram:i02-late", 0)
  linking.redeem("whatsapp:i02-late", code, 600_001)
  |> should.equal(Error(linking.InvalidCode))
}

pub fn a_new_code_replaces_the_old_one_test() {
  let old = linking.issue("telegram:i02-new", 0)
  let new = linking.issue("telegram:i02-new", 10)
  case old == new {
    True -> Nil
    False ->
      linking.redeem("whatsapp:i02-new", old, 20)
      |> should.equal(Error(linking.InvalidCode))
  }
  linking.redeem("whatsapp:i02-new", new, 30)
  |> should.equal(Ok("telegram:i02-new"))
}

pub fn five_wrong_tries_an_hour_test() {
  let claimant = "whatsapp:i02-guess"
  [1, 2, 3, 4, 5]
  |> list.each(fn(i) {
    linking.redeem(claimant, "ZZZZZ" <> string.inspect(i), i)
    |> should.equal(Error(linking.InvalidCode))
  })
  let code = linking.issue("telegram:i02-guess", 10)
  // Even the right code waits now.
  linking.redeem(claimant, code, 20)
  |> should.equal(Error(linking.TooManyTries))
  // An hour after the first wrong try, one slot is free again.
  linking.redeem(claimant, code, 3_600_002)
  |> should.equal(Error(linking.InvalidCode))
  let code = linking.issue("telegram:i02-guess", 3_600_003)
  linking.redeem(claimant, code, 3_600_004)
  |> should.equal(Ok("telegram:i02-guess"))
}
