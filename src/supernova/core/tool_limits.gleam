//// Ceilings on what a tool may cost a turn (PRD-E, E-03): the text a tool
//// result brings to the model, and how long a tool may run.

import gleam/dict.{type Dict}
import gleam/int
import gleam/result
import gleam/string

/// Longest tool result the model sees, in characters (PRD-E, D2).
pub const max_output_chars = 20_000

/// The result whole when it fits; otherwise its start and a notice saying
/// how long it was.
pub fn cap(text: String) -> String {
  let length = string.length(text)
  case length > max_output_chars {
    False -> text
    True ->
      string.slice(text, 0, max_output_chars)
      <> "\n[saída cortada: "
      <> int.to_string(length)
      <> " caracteres; peça um trecho menor]"
  }
}

/// How long a tool may run (PRD-E, D3), in milliseconds.
pub type Timeouts {
  Timeouts(default_ms: Int, per_tool: Dict(String, Int))
}

pub fn default_timeouts() -> Timeouts {
  Timeouts(
    default_ms: 60_000,
    per_tool: dict.from_list([#("computador", 300_000)]),
  )
}

/// Limits from `tools.timeouts` (seconds; `default` for every other tool),
/// over the built-in ones.
pub fn from_seconds(seconds: Dict(String, Int)) -> Timeouts {
  let builtin = default_timeouts()
  let ms = dict.map_values(seconds, fn(_, value) { value * 1000 })
  Timeouts(
    default_ms: dict.get(ms, "default") |> result.unwrap(builtin.default_ms),
    per_tool: dict.merge(builtin.per_tool, dict.delete(ms, "default")),
  )
}

pub fn timeout_ms(timeouts: Timeouts, tool: String) -> Int {
  case dict.get(timeouts.per_tool, tool) {
    Ok(ms) -> ms
    Error(Nil) -> timeouts.default_ms
  }
}

const key = "supernova_tool_timeouts"

@external(erlang, "supernova_global_ffi", "global_put")
fn put(key: String, value: Timeouts) -> Nil

@external(erlang, "supernova_tool_limits_ffi", "get")
fn get(key: String) -> Result(Timeouts, Nil)

/// Set the time limits every turn uses (boot; tests).
pub fn configure(timeouts: Timeouts) -> Nil {
  put(key, timeouts)
}

/// The configured time limits, or the defaults.
pub fn current() -> Timeouts {
  case get(key) {
    Ok(timeouts) -> timeouts
    Error(Nil) -> default_timeouts()
  }
}
