//// Aliases — one person, one agent, in every channel (PRD-I).
////
//// A person's first identity (`telegram:123`) is canonical: it names the
//// agent's folder, access, budget and conversations. Identities linked
//// later (`whatsapp:5511…`) are aliases of it. Every derivation of a
//// principal resolves aliases (`agent_identity`, the closed-group gate),
//// so nothing else needs to know about them.
////
//// The table lives in `<data_dir>/identity/aliases.json`, written
//// atomically, read at boot and kept in memory. An alias never points to
//// another alias.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type Entry {
  Entry(canonical: String, channel: String, linked_at: Int)
}

const key = "supernova_identity_aliases"

@external(erlang, "supernova_global_ffi", "global_put")
fn put(key: String, table: Dict(String, Entry)) -> Nil

@external(erlang, "supernova_tool_limits_ffi", "get")
fn get(key: String) -> Result(Dict(String, Entry), Nil)

@external(erlang, "supernova_aliases_ffi", "locked")
fn locked(work: fn() -> a) -> a

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_access_ffi", "rename")
fn rename(from: String, to: String) -> Result(Nil, String)

fn table() -> Dict(String, Entry) {
  get(key) |> result.unwrap(dict.new())
}

/// The person an identity belongs to: its canonical identity, or itself.
pub fn resolve(principal: String) -> String {
  case dict.get(table(), principal) {
    Ok(entry) -> entry.canonical
    Error(Nil) -> principal
  }
}

/// The identities linked to a person.
pub fn aliases_of(canonical: String) -> List(String) {
  table()
  |> dict.to_list
  |> list.filter(fn(pair) { { pair.1 }.canonical == canonical })
  |> list.map(fn(pair) { pair.0 })
  |> list.sort(string.compare)
}

/// The entry of a linked identity.
pub fn entry(alias: String) -> Result(Entry, Nil) {
  dict.get(table(), alias)
}

/// Link `alias` to the person `target` belongs to.
pub fn link(
  data_dir: String,
  alias: String,
  target: String,
  channel: String,
  now: Int,
) -> Result(Nil, String) {
  use <- locked
  let current = table()
  let canonical = resolve(target)
  case alias == canonical, dict.has_key(current, alias), aliases_of(alias) {
    True, _, _ -> Error("an identity cannot be linked to itself")
    _, True, _ -> Error("this identity is already linked; unlink it first")
    _, _, [_, ..] -> Error("this identity has others linked to it")
    False, False, [] ->
      save(
        data_dir,
        dict.insert(current, alias, Entry(canonical, channel, now)),
      )
  }
}

/// Undo the link of `alias`; it becomes a person of its own again.
pub fn unlink(data_dir: String, alias: String) -> Result(Nil, String) {
  use <- locked
  let current = table()
  case dict.has_key(current, alias) {
    False -> Error("this identity is not linked")
    True -> save(data_dir, dict.delete(current, alias))
  }
}

/// Read the table written by earlier runs (boot). A missing file is an
/// empty table.
pub fn load(data_dir: String) -> Result(Nil, String) {
  case read_file(path(data_dir)) {
    Error(_) -> {
      put(key, dict.new())
      Ok(Nil)
    }
    Ok(text) ->
      case json.parse(text, file_decoder()) {
        Ok(loaded) -> {
          put(key, loaded)
          Ok(Nil)
        }
        Error(_) -> Error("identity/aliases.json is not readable")
      }
  }
}

/// Drop the table in memory (tests: simulate a restart).
pub fn forget_loaded() -> Nil {
  put(key, dict.new())
}

fn path(data_dir: String) -> String {
  data_dir <> "/identity/aliases.json"
}

fn save(data_dir: String, next: Dict(String, Entry)) -> Result(Nil, String) {
  let file = path(data_dir)
  let temp = file <> ".tmp"
  use _ <- result.try(ensure_dir(data_dir <> "/identity"))
  use _ <- result.try(write_file(temp, encode(next)))
  use _ <- result.try(rename(temp, file))
  put(key, next)
  Ok(Nil)
}

fn encode(table: Dict(String, Entry)) -> String {
  json.object([
    #("version", json.int(1)),
    #(
      "aliases",
      json.object(
        table
        |> dict.to_list
        |> list.map(fn(pair) {
          let #(alias, entry) = pair
          #(
            alias,
            json.object([
              #("canonical", json.string(entry.canonical)),
              #("channel", json.string(entry.channel)),
              #("linked_at", json.int(entry.linked_at)),
            ]),
          )
        }),
      ),
    ),
  ])
  |> json.to_string
}

fn file_decoder() -> decode.Decoder(Dict(String, Entry)) {
  let entry = {
    use canonical <- decode.field("canonical", decode.string)
    use channel <- decode.field("channel", decode.string)
    use linked_at <- decode.field("linked_at", decode.int)
    decode.success(Entry(canonical, channel, linked_at))
  }
  decode.at(["aliases"], decode.dict(decode.string, entry))
}
