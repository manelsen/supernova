//// The agent's private self: core prose, traits and biography.

import envoy
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/core/agent_identity
import supernova/self/sampler.{type Sampled}

pub type Core {
  Core(
    version: Int,
    traits: List(String),
    seed: Int,
    attempts: Int,
    constellation_version: Int,
    born_at: Int,
    name: Option(String),
  )
}

pub fn core_path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/core.json"
}

pub fn prose_path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/core.md"
}

pub fn biography_path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/biography.jsonl"
}

pub fn load(data_dir: String, principal: String) -> Option(Core) {
  case read_file(core_path(data_dir, principal)) {
    Error(_) -> None
    Ok(raw) -> decode_core(raw)
  }
}

pub fn save_birth(
  data_dir: String,
  principal: String,
  sampled: Sampled,
  constellation_version: Int,
  prose: String,
  born_at: Int,
) -> Result(Nil, String) {
  let core =
    Core(
      version: 1,
      traits: sampled.traits,
      seed: sampled.seed,
      attempts: sampled.attempts,
      constellation_version: constellation_version,
      born_at: born_at,
      name: None,
    )
  let directory = agent_identity.self_dir(data_dir, principal)
  use _ <- result.try(ensure_dir(directory))
  use _ <- result.try(write_file(
    core_path(data_dir, principal),
    encode_core(core),
  ))
  use _ <- result.try(write_file(prose_path(data_dir, principal), prose))
  use _ <- result.try(append_file(
    biography_path(data_dir, principal),
    json.to_string(
      json.object([
        #("at", json.int(born_at)),
        #("kind", json.string("birth")),
        #("traits", json.array(sampled.traits, json.string)),
      ]),
    )
      <> "\n",
  ))
  Ok(Nil)
}

pub fn set_name(
  data_dir: String,
  principal: String,
  core: Core,
  name: String,
  at: Int,
) -> Result(Nil, String) {
  use _ <- result.try(write_file(
    core_path(data_dir, principal),
    encode_core(Core(..core, name: Some(name))),
  ))
  append_file(
    biography_path(data_dir, principal),
    json.to_string(
      json.object([
        #("at", json.int(at)),
        #("kind", json.string("name")),
        #("name", json.string(name)),
      ]),
    )
      <> "\n",
  )
}

pub fn read_prose(data_dir: String, principal: String) -> Option(String) {
  case read_file(prose_path(data_dir, principal)) {
    Ok(prose) -> Some(prose)
    Error(_) -> None
  }
}

pub fn existing_traits(data_dir: String) -> List(List(String)) {
  find_files(data_dir <> "/agents", "*/self/core.json")
  |> list.filter_map(fn(path) {
    case read_file(path) {
      Error(_) -> Error(Nil)
      Ok(raw) ->
        case decode_core(raw) {
          Some(core) -> Ok(core.traits)
          None -> Error(Nil)
        }
    }
  })
}

pub fn valid_name(name: String) -> Bool {
  let trimmed = string.trim(name)
  let length = string.length(trimmed)
  length >= 1
  && length <= 40
  && !string.contains(trimmed, "/")
  && has_ascii_letter(trimmed)
}

fn decode_core(raw: String) -> Option(Core) {
  let decoder = {
    use version <- decode.field("version", decode.int)
    use traits <- decode.field("traits", decode.list(decode.string))
    use seed <- decode.field("seed", decode.int)
    use attempts <- decode.field("attempts", decode.int)
    use constellation_version <- decode.field(
      "constellation_version",
      decode.int,
    )
    use born_at <- decode.field("born_at", decode.int)
    use name <- decode.optional_field(
      "name",
      None,
      decode.optional(decode.string),
    )
    decode.success(Core(
      version: version,
      traits: traits,
      seed: seed,
      attempts: attempts,
      constellation_version: constellation_version,
      born_at: born_at,
      name: name,
    ))
  }
  case json.parse(from: raw, using: decoder) {
    Ok(core) -> Some(core)
    Error(_) -> None
  }
}

fn encode_core(core: Core) -> String {
  json.to_string(
    json.object([
      #("version", json.int(core.version)),
      #("traits", json.array(core.traits, json.string)),
      #("seed", json.int(core.seed)),
      #("attempts", json.int(core.attempts)),
      #("constellation_version", json.int(core.constellation_version)),
      #("born_at", json.int(core.born_at)),
      #("name", case core.name {
        Some(name) -> json.string(name)
        None -> json.null()
      }),
    ]),
  )
}

pub fn constellation_path() -> String {
  case envoy.get("SUPERNOVA_CONSTELLATION_PATH") {
    Ok(path) -> path
    Error(_) -> "priv/constellation/constellation.json"
  }
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "append_file")
fn append_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "find_files")
fn find_files(dir: String, pattern: String) -> List(String)

@external(erlang, "supernova_self_ffi", "has_ascii_letter")
fn has_ascii_letter(value: String) -> Bool
