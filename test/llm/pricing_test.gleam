//// Tests for LLM Pricing
////
//// Pure tests — no I/O, no clock.

import gleam/dict
import gleam/float
import gleeunit
import gleeunit/should
import supernova/llm/pricing.{Price, cost_usd, day_key, price_for}

pub fn main() -> Nil {
  gleeunit.main()
}

fn assert_close(actual: Float, expected: Float) -> Nil {
  should.be_true(float.absolute_value(actual -. expected) <. 1.0e-12)
}

// ============================================================================
// cost_usd
// ============================================================================

pub fn cost_usd_with_price_test() {
  let price = Price(input_per_mtok: 3.0, output_per_mtok: 15.0)

  // 1000 input @ $3/MTok + 500 output @ $15/MTok
  assert_close(cost_usd(price, 1000, 500), 0.0105)
}

pub fn cost_usd_zero_tokens_test() {
  let price = Price(input_per_mtok: 3.0, output_per_mtok: 15.0)

  assert_close(cost_usd(price, 0, 0), 0.0)
}

pub fn cost_usd_prompt_only_test() {
  let price = Price(input_per_mtok: 1.0, output_per_mtok: 100.0)

  assert_close(cost_usd(price, 1_000_000, 0), 1.0)
}

// ============================================================================
// price_for
// ============================================================================

pub fn price_for_known_model_test() {
  let default = Price(input_per_mtok: 1.0, output_per_mtok: 2.0)
  let models =
    dict.from_list([
      #("model-a", Price(input_per_mtok: 3.0, output_per_mtok: 15.0)),
    ])

  let price = price_for("model-a", default, models)
  price.input_per_mtok
  |> should.equal(3.0)
  price.output_per_mtok
  |> should.equal(15.0)
}

pub fn price_for_unknown_model_uses_default_test() {
  let default = Price(input_per_mtok: 1.0, output_per_mtok: 2.0)
  let models =
    dict.from_list([
      #("model-a", Price(input_per_mtok: 3.0, output_per_mtok: 15.0)),
    ])

  let price = price_for("model-b", default, models)
  price.input_per_mtok
  |> should.equal(1.0)
  price.output_per_mtok
  |> should.equal(2.0)
}

// ============================================================================
// day_key
// ============================================================================

pub fn day_key_utc_test() {
  // 2024-06-15T12:00:00Z
  day_key(1_718_452_800_000, "UTC")
  |> should.equal("2024-06-15")
}

pub fn day_key_utc_rollover_test() {
  // 2024-01-02T00:00:00Z
  day_key(1_704_153_600_000, "UTC")
  |> should.equal("2024-01-02")
}

pub fn day_key_sao_paulo_before_midnight_test() {
  // 2024-01-01T02:59:00Z = 2023-12-31T23:59 in Sao Paulo (UTC-03:00)
  day_key(1_704_077_940_000, "America/Sao_Paulo")
  |> should.equal("2023-12-31")
}

pub fn day_key_sao_paulo_after_midnight_test() {
  // 2024-01-01T03:00:00Z = 2024-01-01T00:00 in Sao Paulo (UTC-03:00)
  day_key(1_704_078_000_000, "America/Sao_Paulo")
  |> should.equal("2024-01-01")
}

pub fn day_key_unknown_timezone_falls_back_to_utc_test() {
  // 2024-01-01T02:59:00Z is 2023-12-31 in Sao Paulo but still 2024-01-01 in
  // UTC, so an unknown zone must behave like UTC.
  day_key(1_704_077_940_000, "Mars/Olympus")
  |> should.equal("2024-01-01")
}
