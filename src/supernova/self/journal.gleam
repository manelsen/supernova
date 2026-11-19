//// Append-only journal of turns not yet reflected.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import supernova/core/agent_identity

pub type Entry {
  Entry(at: Int, origin: String, session: String, user: String, agent: String)
}

pub fn path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/journal.jsonl"
}

fn encode(entry: Entry) -> String {
  json.to_string(
    json.object([
      #("at", json.int(entry.at)),
      #("origin", json.string(entry.origin)),
      #("session", json.string(entry.session)),
      #("user", json.string(entry.user)),
      #("agent", json.string(entry.agent)),
    ]),
  )
}

fn decoder() -> decode.Decoder(Entry) {
  use at <- decode.field("at", decode.int)
  use origin <- decode.field("origin", decode.string)
  use session <- decode.field("session", decode.string)
  use user <- decode.optional_field("user", "", decode.string)
  use agent <- decode.optional_field("agent", "", decode.string)
  decode.success(Entry(
    at: at,
    origin: origin,
    session: session,
    user: user,
    agent: agent,
  ))
}

pub fn load(data_dir: String, principal: String) -> List(Entry) {
  case read_file(path(data_dir, principal)) {
    Error(_) -> []
    Ok(raw) ->
      raw
      |> string.split("\n")
      |> list.filter(fn(line) { string.trim(line) != "" })
      |> list.filter_map(fn(line) {
        case json.parse(from: line, using: decoder()) {
          Ok(entry) -> Ok(entry)
          Error(_) -> Error(Nil)
        }
      })
  }
}

/// Append a turn and keep at most `limit` entries. Returns how many were trimmed.
pub fn append(
  data_dir: String,
  principal: String,
  entry: Entry,
  limit: Int,
) -> Result(Int, String) {
  with_lock(path(data_dir, principal), fn() {
    let existing = load(data_dir, principal)
    let trimmed = int.max(0, list.length(existing) + 1 - limit)
    let kept = case limit {
      x if x <= 0 -> []
      _ -> {
        let combined = list.append(existing, [entry])
        list.drop(combined, list.length(combined) - limit)
      }
    }
    use _ <- result.try(
      ensure_dir(agent_identity.self_dir(data_dir, principal)),
    )
    use _ <- result.try(write_file(
      path(data_dir, principal),
      string.join(list.map(kept, encode), "\n") <> "\n",
    ))
    Ok(trimmed)
  })
}

pub fn replace(
  data_dir: String,
  principal: String,
  entries: List(Entry),
) -> Result(Nil, String) {
  use _ <- result.try(ensure_dir(agent_identity.self_dir(data_dir, principal)))
  write_file(path(data_dir, principal), case entries {
    [] -> ""
    _ -> string.join(list.map(entries, encode), "\n") <> "\n"
  })
}

pub fn remove_many(
  data_dir: String,
  principal: String,
  reflected: List(Entry),
) -> Result(Nil, String) {
  let remaining =
    load(data_dir, principal)
    |> list.filter(fn(entry) { !list.contains(reflected, entry) })
  replace(data_dir, principal, remaining)
}

pub fn without_origin(
  data_dir: String,
  principal: String,
  origin: String,
) -> #(List(Entry), Int) {
  let all = load(data_dir, principal)
  let kept = list.filter(all, fn(entry) { entry.origin != origin })
  #(kept, list.length(all) - list.length(kept))
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_self_ffi", "with_lock")
fn with_lock(key: String, body: fn() -> a) -> a
