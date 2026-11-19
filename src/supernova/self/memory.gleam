//// Experiences, pressures and prose addenda kept in the agent's self directory.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import supernova/core/agent_identity

pub type Experience {
  Experience(at: Int, origin: String, text: String)
}

pub type Pressure {
  Pressure(
    at: Int,
    origin: String,
    from: String,
    to: String,
    strength: Float,
    reason: String,
  )
}

pub fn experience_path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/experience.jsonl"
}

pub fn pressure_path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/pressure.jsonl"
}

pub fn addenda_path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/addenda.md"
}

fn encode_experience(item: Experience) -> String {
  json.to_string(
    json.object([
      #("at", json.int(item.at)),
      #("origin", json.string(item.origin)),
      #("text", json.string(item.text)),
    ]),
  )
}

fn encode_pressure(item: Pressure) -> String {
  json.to_string(
    json.object([
      #("at", json.int(item.at)),
      #("origin", json.string(item.origin)),
      #("from", json.string(item.from)),
      #("to", json.string(item.to)),
      #("strength", json.float(item.strength)),
      #("reason", json.string(item.reason)),
    ]),
  )
}

fn experience_decoder() -> decode.Decoder(Experience) {
  use at <- decode.field("at", decode.int)
  use origin <- decode.field("origin", decode.string)
  use text <- decode.field("text", decode.string)
  decode.success(Experience(at: at, origin: origin, text: text))
}

fn pressure_decoder() -> decode.Decoder(Pressure) {
  use at <- decode.field("at", decode.int)
  use origin <- decode.field("origin", decode.string)
  use from <- decode.field("from", decode.string)
  use to <- decode.field("to", decode.string)
  use strength <- decode.field("strength", decode.float)
  use reason <- decode.field("reason", decode.string)
  decode.success(Pressure(
    at: at,
    origin: origin,
    from: from,
    to: to,
    strength: strength,
    reason: reason,
  ))
}

fn read_jsonl(path: String, decoder: decode.Decoder(a)) -> List(a) {
  case read_file(path) {
    Error(_) -> []
    Ok(raw) ->
      raw
      |> string.split("\n")
      |> list.filter(fn(line) { string.trim(line) != "" })
      |> list.filter_map(fn(line) {
        case json.parse(from: line, using: decoder) {
          Ok(item) -> Ok(item)
          Error(_) -> Error(Nil)
        }
      })
  }
}

pub fn experiences(data_dir: String, principal: String) -> List(Experience) {
  read_jsonl(experience_path(data_dir, principal), experience_decoder())
}

pub fn recent_experiences(
  data_dir: String,
  principal: String,
  limit: Int,
) -> List(Experience) {
  experiences(data_dir, principal)
  |> list.reverse
  |> list.take(limit)
  |> list.reverse
}

pub fn pressures(data_dir: String, principal: String) -> List(Pressure) {
  read_jsonl(pressure_path(data_dir, principal), pressure_decoder())
}

fn append_json_lines(
  data_dir: String,
  principal: String,
  path: String,
  lines: List(String),
) -> Result(Nil, String) {
  use _ <- result.try(ensure_dir(agent_identity.self_dir(data_dir, principal)))
  append_file(path, string.join(lines, "\n") <> "\n")
}

pub fn append_experiences(
  data_dir: String,
  principal: String,
  items: List(Experience),
) -> Result(Nil, String) {
  append_json_lines(
    data_dir,
    principal,
    experience_path(data_dir, principal),
    list.map(items, encode_experience),
  )
}

pub fn append_pressures(
  data_dir: String,
  principal: String,
  items: List(Pressure),
) -> Result(Nil, String) {
  append_json_lines(
    data_dir,
    principal,
    pressure_path(data_dir, principal),
    list.map(items, encode_pressure),
  )
}

pub fn replace_pressures(
  data_dir: String,
  principal: String,
  items: List(Pressure),
) -> Result(Nil, String) {
  use _ <- result.try(ensure_dir(agent_identity.self_dir(data_dir, principal)))
  let body = case items {
    [] -> ""
    _ -> string.join(list.map(items, encode_pressure), "\n") <> "\n"
  }
  write_file(pressure_path(data_dir, principal), body)
}

pub fn without_origin_experiences(
  data_dir: String,
  principal: String,
  origin: String,
) -> #(List(Experience), Int) {
  let all = experiences(data_dir, principal)
  let kept = list.filter(all, fn(item) { item.origin != origin })
  #(kept, list.length(all) - list.length(kept))
}

pub fn without_origin_pressures(
  data_dir: String,
  principal: String,
  origin: String,
) -> #(List(Pressure), Int) {
  let all = pressures(data_dir, principal)
  let kept = list.filter(all, fn(item) { item.origin != origin })
  #(kept, list.length(all) - list.length(kept))
}

pub fn replace_experiences(
  data_dir: String,
  principal: String,
  items: List(Experience),
) -> Result(Nil, String) {
  use _ <- result.try(ensure_dir(agent_identity.self_dir(data_dir, principal)))
  let body = case items {
    [] -> ""
    _ -> string.join(list.map(items, encode_experience), "\n") <> "\n"
  }
  write_file(experience_path(data_dir, principal), body)
}

pub fn addenda(data_dir: String, principal: String) -> String {
  case read_file(addenda_path(data_dir, principal)) {
    Ok(text) -> text
    Error(_) -> ""
  }
}

pub fn append_addendum(
  data_dir: String,
  principal: String,
  text: String,
) -> Result(Nil, String) {
  use _ <- result.try(ensure_dir(agent_identity.self_dir(data_dir, principal)))
  append_file(
    addenda_path(data_dir, principal),
    "\n\n" <> string.trim(text) <> "\n",
  )
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "append_file")
fn append_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)
