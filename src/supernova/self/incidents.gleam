//// What went wrong in the agent's own turns, in exact terms: the provider
//// refusing a request, a tool failing, an agenda entry skipped.
////
//// The agent reads the recent ones in its prompt, so it knows what happened
//// instead of guessing; its guidance tells it to explain simply by default
//// and give these details when asked. Entries never carry conversation text,
//// keys or anything about other people. /esquecer clears them.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import supernova/agenda/schedule
import supernova/core/agent_identity

pub type Incident {
  Incident(at: Int, text: String)
}

/// How many incidents the file keeps.
pub const max_kept = 50

/// The longest text an incident keeps, in characters.
pub const max_text_length = 240

/// How long an incident stays in the prompt.
pub const window_ms = 604_800_000

pub fn path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/incidents.jsonl"
}

pub fn record(
  data_dir: String,
  principal: String,
  at: Int,
  text: String,
) -> Result(Nil, String) {
  record_if(data_dir, principal, at, text, fn() { True })
}

/// Record only if `still_current()` holds, checked inside the lock. A
/// producer racing /esquecer passes an epoch check: /esquecer bumps the epoch
/// before it clears, so a write that gets the lock after the clear sees the
/// new epoch and is dropped.
pub fn record_if(
  data_dir: String,
  principal: String,
  at: Int,
  text: String,
  still_current: fn() -> Bool,
) -> Result(Nil, String) {
  let incident = Incident(at: at, text: clean(text))
  with_lock("incidents:" <> principal, fn() {
    case still_current() {
      False -> Ok(Nil)
      True -> {
        use current <- result.try(load(data_dir, principal))
        let kept =
          list.append(current, [incident])
          |> by_time
          |> keep_last(max_kept)
        save(data_dir, principal, kept)
      }
    }
  })
}

/// The last `limit` incidents of the past week, oldest first.
pub fn recent(
  data_dir: String,
  principal: String,
  now: Int,
  limit: Int,
) -> List(Incident) {
  load(data_dir, principal)
  |> result.unwrap([])
  |> list.filter(fn(incident) {
    incident.at <= now && now - incident.at <= window_ms
  })
  |> by_time
  |> keep_last(limit)
}

pub fn count(data_dir: String, principal: String) -> Int {
  load(data_dir, principal) |> result.unwrap([]) |> list.length
}

pub fn clear(data_dir: String, principal: String) -> Result(Int, String) {
  with_lock("incidents:" <> principal, fn() {
    // Forgetting removes the file even when it cannot be read.
    let count = load(data_dir, principal) |> result.unwrap([]) |> list.length
    delete_file(path(data_dir, principal))
    |> result.replace(count)
  })
}

/// The prompt section, empty when nothing happened.
pub fn prompt_block(incidents: List(Incident), offset: Int) -> String {
  case incidents {
    [] -> ""
    _ ->
      "O que aconteceu por aqui:\n"
      <> {
        incidents
        |> list.map(fn(incident) {
          "- "
          <> schedule.format_local(incident.at, offset)
          <> ": "
          <> incident.text
        })
        |> string.join("\n")
      }
  }
}

fn clean(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.map(fn(cp) {
    case string.utf_codepoint_to_int(cp) < 32 {
      True -> " "
      False -> string.from_utf_codepoints([cp])
    }
  })
  |> string.concat
  |> string.trim
  |> fn(text) {
    case string.length(text) > max_text_length {
      True -> string.slice(text, 0, max_text_length - 3) <> "..."
      False -> text
    }
  }
}

fn by_time(incidents: List(Incident)) -> List(Incident) {
  list.sort(incidents, fn(a, b) { int.compare(a.at, b.at) })
}

fn keep_last(items: List(a), count: Int) -> List(a) {
  list.drop(items, int.max(0, list.length(items) - count))
}

/// A missing file is no incidents; a file that cannot be read is an error,
/// so a write never replaces a history it could not see. A line that does
/// not decode is skipped.
fn load(data_dir: String, principal: String) -> Result(List(Incident), String) {
  let file = path(data_dir, principal)
  case file_exists(file) {
    Error(reason) -> Error(reason)
    Ok(False) -> Ok([])
    Ok(True) -> {
      use text <- result.try(read_file(file))
      Ok(
        string.split(text, "\n")
        |> list.filter_map(fn(line) {
          json.parse(line, {
            use at <- decode.field("at", decode.int)
            use text <- decode.field("text", decode.string)
            decode.success(Incident(at:, text:))
          })
          |> result.replace_error(Nil)
        }),
      )
    }
  }
}

fn save(
  data_dir: String,
  principal: String,
  incidents: List(Incident),
) -> Result(Nil, String) {
  let file = path(data_dir, principal)
  let body =
    incidents
    |> list.map(fn(incident) {
      json.object([
        #("at", json.int(incident.at)),
        #("text", json.string(incident.text)),
      ])
      |> json.to_string
    })
    |> string.join("\n")
  use _ <- result.try(ensure_dir(agent_identity.self_dir(data_dir, principal)))
  use _ <- result.try(write_file(file <> ".tmp", body <> "\n"))
  rename(file <> ".tmp", file)
}

@external(erlang, "supernova_self_ffi", "with_lock")
fn with_lock(key: String, body: fn() -> a) -> a

@external(erlang, "supernova_self_ffi", "rename_file")
fn rename(from: String, to: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn delete_file(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)
