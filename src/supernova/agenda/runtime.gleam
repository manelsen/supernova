//// Where the agenda lives and what time it is, published once at boot.
////
//// Kept apart from the closed-group globals so the agenda tool, which the
//// syscall gateway calls, does not import the gateway back.

import gleam/option.{type Option, None, Some}

pub type Context {
  Context(data_dir: String, offset_minutes: Int, clock: fn() -> Int)
}

const key = "supernova_agenda_context"

pub fn configure(context: Context) -> Nil {
  global_put(key, context)
}

/// Turn the agenda off, for instance when the timezone is unsupported.
pub fn clear() -> Nil {
  global_erase(key)
}

pub fn get() -> Option(Context) {
  case global_has(key) {
    True -> Some(global_get(key))
    False -> None
  }
}

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: a) -> Nil

@external(erlang, "supernova_global_ffi", "global_get")
fn global_get(key: String) -> a

@external(erlang, "supernova_global_ffi", "global_has")
fn global_has(key: String) -> Bool

@external(erlang, "supernova_global_ffi", "global_erase")
fn global_erase(key: String) -> Nil
