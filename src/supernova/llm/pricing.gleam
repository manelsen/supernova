//// LLM Pricing — Pure cost calculation.
////
//// Prices are expressed in USD per million tokens (MTok), which is the
//// convention used by most LLM providers. Everything in this module is pure:
//// no clock access, no I/O.
////
//// ## Usage
////
//// ```gleam
//// let price = Price(input_per_mtok: 3.0, output_per_mtok: 15.0)
//// cost_usd(price, 1_000, 500)
//// // -> 0.0105
//// ```

import gleam/dict.{type Dict}
import gleam/int
import gleam/result
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp

// ============================================================================
// Types
// ============================================================================

/// Price of a model, in USD per million tokens.
pub type Price {
  Price(input_per_mtok: Float, output_per_mtok: Float)
}

/// Fixed offset of America/Sao_Paulo. Brazil abolished DST in 2019, so the
/// zone is a constant UTC-03:00 for all current timestamps.
const sao_paulo_offset_hours: Int = -3

const tokens_per_million: Float = 1_000_000.0

// ============================================================================
// Public API
// ============================================================================

/// Cost in USD for a call with the given token counts.
pub fn cost_usd(
  price: Price,
  prompt_tokens: Int,
  completion_tokens: Int,
) -> Float {
  let input_cost =
    int.to_float(prompt_tokens) /. tokens_per_million *. price.input_per_mtok
  let output_cost =
    int.to_float(completion_tokens)
    /. tokens_per_million
    *. price.output_per_mtok
  input_cost +. output_cost
}

/// Look up the price for a model, falling back to `default` when the model is
/// unknown.
pub fn price_for(
  model: String,
  default: Price,
  models: Dict(String, Price),
) -> Price {
  dict.get(models, model)
  |> result.unwrap(default)
}

/// Calendar day of a timestamp in the given timezone, formatted `YYYY-MM-DD`.
///
/// Supported timezones:
/// - `"UTC"` (and any unknown timezone, which falls back to UTC)
/// - `"America/Sao_Paulo"` (fixed UTC-03:00)
pub fn day_key(timestamp_ms: Int, timezone: String) -> String {
  let offset = case timezone {
    "America/Sao_Paulo" -> duration.hours(sao_paulo_offset_hours)
    _ -> calendar.utc_offset
  }

  let seconds =
    int.floor_divide(timestamp_ms, 1000)
    |> result.unwrap(0)

  let #(date, _time) =
    timestamp.from_unix_seconds(seconds)
    |> timestamp.to_calendar(offset)

  int.to_string(date.year)
  <> "-"
  <> pad2(calendar.month_to_int(date.month))
  <> "-"
  <> pad2(date.day)
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn pad2(value: Int) -> String {
  case value < 10 {
    True -> "0" <> int.to_string(value)
    False -> int.to_string(value)
  }
}
