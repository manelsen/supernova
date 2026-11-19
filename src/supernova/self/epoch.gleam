//// Forget epoch: a counter bumped by every /esquecer.
////
//// Work that started under an older epoch (a turn or a reflection already in
//// flight) must not write memory after the owner asked to forget.

import gleam/int
import gleam/result
import gleam/string
import supernova/core/agent_identity

fn path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/forget_epoch"
}

/// Current epoch; 0 when the agent never forgot anything.
pub fn current(data_dir: String, principal: String) -> Int {
  case read_file(path(data_dir, principal)) {
    Ok(raw) -> int.parse(string.trim(raw)) |> result.unwrap(0)
    Error(_) -> 0
  }
}

/// Bump the epoch and return the new value.
pub fn bump(data_dir: String, principal: String) -> Result(Int, String) {
  let next = current(data_dir, principal) + 1
  use _ <- result.try(ensure_dir(agent_identity.self_dir(data_dir, principal)))
  use _ <- result.try(write_file(path(data_dir, principal), int.to_string(next)))
  Ok(next)
}

/// True when nothing was forgotten since `started`.
pub fn unchanged(data_dir: String, principal: String, started: Int) -> Bool {
  current(data_dir, principal) == started
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)
