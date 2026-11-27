//// Deleting a person's message from a chat, where the channel allows it
//// (PRD-K, K-08: the message that carried a password). Set at boot; a
//// channel without it answers Error, and the person is asked to delete it.

import gleam/option.{type Option, None, Some}

pub type Deleter =
  fn(String, String, String) -> Result(Nil, String)

const key = "supernova_apagar_mensagem"

pub fn configure(deleter: Deleter) -> Nil {
  global_put(key, deleter)
}

pub fn clear() -> Nil {
  global_erase(key)
}

/// Delete `message_id` in `chat_id` of `channel`.
pub fn apagar(
  channel: String,
  chat_id: String,
  message_id: String,
) -> Result(Nil, String) {
  case get() {
    Some(deleter) -> deleter(channel, chat_id, message_id)
    None -> Error("no channel deletes messages here")
  }
}

fn get() -> Option(Deleter) {
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
