//// Tools that exist only for the stress run and the tests (PRD-F, F-01):
//// `lenta` sleeps, `trava` never answers, `explode` crashes. They are off
//// unless `enable` was called, so production never offers or runs them.
////
//// A test can watch them: `observe` gives a subject that receives the pid of
//// every fake tool call as it starts, to check later that nothing was left
//// alive (I2).

import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import supernova/llm/provider

const enabled_key = "supernova_fake_tools_enabled"

const observer_key = "supernova_fake_tools_observer"

pub const names = ["lenta", "trava", "explode"]

/// Turn the fake tools on (stress run, tests).
pub fn enable() -> Nil {
  global_put(enabled_key, True)
}

pub fn disable() -> Nil {
  global_erase(enabled_key)
  global_erase(observer_key)
}

pub fn enabled() -> Bool {
  global_has(enabled_key)
}

/// Every fake tool call sends its own pid here when it starts.
pub fn observe(observer: Subject(Pid)) -> Nil {
  global_put(observer_key, observer)
}

pub fn is_fake(name: String) -> Bool {
  name == "lenta" || name == "trava" || name == "explode"
}

/// The definitions offered to the model, only when enabled.
pub fn tools() -> List(provider.ToolDefinition) {
  case enabled() {
    False -> []
    True -> [
      provider.ToolDefinition(
        name: "lenta",
        description: "Test tool: waits `ms` milliseconds and answers.",
        parameters: [provider.integer_param("ms", "How long to wait", True)],
      ),
      provider.ToolDefinition(
        name: "trava",
        description: "Test tool: never answers.",
        parameters: [],
      ),
      provider.ToolDefinition(
        name: "explode",
        description: "Test tool: crashes.",
        parameters: [],
      ),
    ]
  }
}

/// Run a fake tool; None when the name is not one of them or they are off.
pub fn execute(
  name: String,
  args_json: String,
) -> Option(Result(String, String)) {
  case enabled(), name {
    False, _ -> None
    True, "lenta" -> {
      announce()
      let ms =
        json.parse(args_json, decode.at(["ms"], decode.int))
        |> option.from_result
        |> option.unwrap(100)
      process.sleep(ms)
      Some(Ok("lenta: " <> int.to_string(ms) <> " ms"))
    }
    True, "trava" -> {
      announce()
      process.sleep_forever()
      Some(Error("unreachable"))
    }
    True, "explode" -> {
      announce()
      panic as "explode: a ferramenta de teste quebrou"
    }
    True, _ -> None
  }
}

fn announce() -> Nil {
  case global_has(observer_key) {
    True -> process.send(observer(observer_key), process.self())
    False -> Nil
  }
}

@external(erlang, "supernova_global_ffi", "global_get")
fn observer(key: String) -> Subject(Pid)

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: a) -> Nil

@external(erlang, "supernova_global_ffi", "global_has")
fn global_has(key: String) -> Bool

@external(erlang, "supernova_global_ffi", "global_erase")
fn global_erase(key: String) -> Nil
