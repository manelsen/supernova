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

/// Read the epoch. A missing file is epoch 0; anything unreadable is an
/// error, so callers fail closed instead of mistaking it for epoch 0.
pub fn read(data_dir: String, principal: String) -> Result(Int, String) {
  let file = path(data_dir, principal)
  case file_exists(file) {
    Ok(False) -> Ok(0)
    Ok(True) ->
      case read_file(file) {
        Error(reason) -> Error(reason)
        Ok(raw) ->
          case int.parse(string.trim(raw)) {
            Ok(value) -> Ok(value)
            Error(_) -> Error("unreadable forget epoch")
          }
      }
    Error(reason) -> Error(reason)
  }
}

/// Epoch to record when work starts. An unreadable epoch yields -1, which
/// never matches, so that work is discarded.
pub fn current(data_dir: String, principal: String) -> Int {
  result.unwrap(read(data_dir, principal), -1)
}

/// Bump the epoch, publishing it atomically (write a temp file, then rename).
pub fn bump(data_dir: String, principal: String) -> Result(Int, String) {
  let file = path(data_dir, principal)
  let next = case read(data_dir, principal) {
    Ok(value) -> value + 1
    // Unreadable: move past anything a reader could have recorded.
    Error(_) -> 1_000_000
  }
  use _ <- result.try(ensure_dir(agent_identity.self_dir(data_dir, principal)))
  use _ <- result.try(write_file(file <> ".tmp", int.to_string(next)))
  use _ <- result.try(rename(file <> ".tmp", file))
  Ok(next)
}

/// True only when the epoch is readable and equal to `started`.
pub fn unchanged(data_dir: String, principal: String, started: Int) -> Bool {
  read(data_dir, principal) == Ok(started)
}

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_self_ffi", "rename_file")
fn rename(from: String, to: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)
