//// The agent's private self: core prose, traits and biography.

import envoy
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/core/agent_identity
import supernova/self/memory
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
    prose_sha256: Option(String),
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

pub fn drift_pending_path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/drift_pending.json"
}

/// A drift waiting to be completed. Written before any file changes so the
/// kernel can finish an interrupted change on the next read.
pub type DriftPending {
  DriftPending(from: String, to: String, addendum: String, at: Int)
}

pub fn write_drift_pending(
  data_dir: String,
  principal: String,
  pending: DriftPending,
) -> Result(Nil, String) {
  ensure_dir(agent_identity.self_dir(data_dir, principal))
  |> result.try(fn(_) {
    write_file(
      drift_pending_path(data_dir, principal),
      json.to_string(
        json.object([
          #("from", json.string(pending.from)),
          #("to", json.string(pending.to)),
          #("addendum", json.string(pending.addendum)),
          #("at", json.int(pending.at)),
        ]),
      ),
    )
  })
}

fn decode_drift_pending(raw: String) -> Option(DriftPending) {
  let decoder = {
    use from <- decode.field("from", decode.string)
    use to <- decode.field("to", decode.string)
    use addendum <- decode.field("addendum", decode.string)
    use at <- decode.field("at", decode.int)
    decode.success(DriftPending(from: from, to: to, addendum: addendum, at: at))
  }
  case json.parse(from: raw, using: decoder) {
    Ok(pending) -> Some(pending)
    Error(_) -> None
  }
}

/// Finish every pending drift step, in order. Each step is idempotent, so
/// running it again after an interruption is safe. The pending file is only
/// removed once every step succeeds.
pub fn complete_drift(
  data_dir: String,
  principal: String,
) -> Result(Nil, String) {
  case read_file(drift_pending_path(data_dir, principal)) {
    Error(_) -> Ok(Nil)
    Ok(raw) ->
      case decode_drift_pending(raw) {
        None -> Error("invalid drift_pending.json")
        Some(pending) -> apply_pending(data_dir, principal, pending)
      }
  }
}

fn apply_pending(
  data_dir: String,
  principal: String,
  pending: DriftPending,
) -> Result(Nil, String) {
  let addendum = string.trim(pending.addendum)
  // Step 2a: addenda.md, without duplicating the paragraph.
  use _ <- result.try(
    case string.contains(memory.addenda(data_dir, principal), addendum) {
      True -> Ok(Nil)
      False -> memory.append_addendum(data_dir, principal, addendum)
    },
  )
  // Step 2b: core.json traits.
  use _ <- result.try(case load_raw(data_dir, principal) {
    None -> Error("missing core")
    Some(core) ->
      case list.contains(core.traits, pending.from) {
        False -> Ok(Nil)
        True ->
          save(
            data_dir,
            principal,
            Core(
              ..core,
              traits: list.map(core.traits, fn(id) {
                case id == pending.from {
                  True -> pending.to
                  False -> id
                }
              }),
            ),
          )
      }
  })
  // Step 2c: biography, without duplicating the drift entry.
  use _ <- result.try(case drift_entry_exists(data_dir, principal, pending) {
    True -> Ok(Nil)
    False ->
      append_biography_entry(
        data_dir,
        principal,
        json.to_string(
          json.object([
            #("at", json.int(pending.at)),
            #("kind", json.string("drift")),
            #("from", json.string(pending.from)),
            #("to", json.string(pending.to)),
            #("reason", json.string(addendum)),
          ]),
        ),
      )
  })
  // Step 3: drop the pressures of this pair.
  let remaining =
    memory.pressures(data_dir, principal)
    |> list.filter(fn(item) {
      !{ item.from == pending.from && item.to == pending.to }
    })
  use _ <- result.try(memory.replace_pressures(data_dir, principal, remaining))
  // Step 4: the change is complete.
  delete_file(drift_pending_path(data_dir, principal))
}

fn drift_entry_exists(
  data_dir: String,
  principal: String,
  pending: DriftPending,
) -> Bool {
  case read_file(biography_path(data_dir, principal)) {
    Error(_) -> False
    Ok(raw) ->
      raw
      |> string.split("\n")
      |> list.filter(fn(line) { string.trim(line) != "" })
      |> list.any(fn(line) {
        case json.parse(from: line, using: drift_identity_decoder()) {
          Ok(#(at, from, to)) ->
            at == pending.at && from == pending.from && to == pending.to
          Error(_) -> False
        }
      })
  }
}

fn drift_identity_decoder() -> decode.Decoder(#(Int, String, String)) {
  use kind <- decode.field("kind", decode.string)
  use at <- decode.field("at", decode.int)
  use from <- decode.field("from", decode.string)
  use to <- decode.field("to", decode.string)
  case kind {
    "drift" -> decode.success(#(at, from, to))
    _ -> decode.failure(#(0, "", ""), "not a drift")
  }
}

/// True when a core file exists, even if unreadable.
pub fn exists(data_dir: String, principal: String) -> Bool {
  case file_exists(core_path(data_dir, principal)) {
    Ok(value) -> value
    Error(_) -> True
  }
}

pub fn load(data_dir: String, principal: String) -> Option(Core) {
  let _ = complete_drift(data_dir, principal)
  load_raw(data_dir, principal)
}

fn load_raw(data_dir: String, principal: String) -> Option(Core) {
  case read_file(core_path(data_dir, principal)) {
    Error(_) -> None
    Ok(raw) ->
      case decode_core(raw) {
        Some(core) -> Some(ensure_prose_hash(data_dir, principal, core))
        None -> None
      }
  }
}

fn ensure_prose_hash(data_dir: String, principal: String, core: Core) -> Core {
  case core.prose_sha256 {
    Some(_) -> core
    None ->
      case read_file(prose_path(data_dir, principal)) {
        Error(_) -> core
        Ok(prose) -> {
          let migrated = Core(..core, prose_sha256: Some(sha256_hex(prose)))
          let _ =
            write_file(core_path(data_dir, principal), encode_core(migrated))
          migrated
        }
      }
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
      prose_sha256: Some(sha256_hex(prose)),
    )
  let directory = agent_identity.self_dir(data_dir, principal)
  use _ <- result.try(ensure_dir(directory))
  let json_path = core_path(data_dir, principal)
  let md_path = prose_path(data_dir, principal)
  case write_file(md_path, prose) {
    Error(error) -> Error(error)
    Ok(_) ->
      case write_file(json_path, encode_core(core)) {
        Error(error) -> {
          let _ = delete_file(md_path)
          Error(error)
        }
        Ok(_) ->
          case
            append_file(
              biography_path(data_dir, principal),
              json.to_string(
                json.object([
                  #("at", json.int(born_at)),
                  #("kind", json.string("birth")),
                  #("traits", json.array(sampled.traits, json.string)),
                ]),
              )
                <> "\n",
            )
          {
            Error(error) -> {
              let _ = delete_file(json_path)
              let _ = delete_file(md_path)
              Error(error)
            }
            Ok(_) -> Ok(Nil)
          }
      }
  }
}

/// Persist a core whose traits may have drifted. Prose is never rewritten here.
pub fn save(
  data_dir: String,
  principal: String,
  core: Core,
) -> Result(Nil, String) {
  write_file(core_path(data_dir, principal), encode_core(core))
}

/// Append one raw biography entry (already JSON-encoded).
pub fn append_biography_entry(
  data_dir: String,
  principal: String,
  entry: String,
) -> Result(Nil, String) {
  append_file(biography_path(data_dir, principal), entry <> "\n")
}

/// Most recent drift timestamp in the biography, or 0.
pub fn last_drift_at(data_dir: String, principal: String) -> Int {
  case read_file(biography_path(data_dir, principal)) {
    Error(_) -> 0
    Ok(raw) ->
      raw
      |> string.split("\n")
      |> list.filter_map(fn(line) {
        case json.parse(from: line, using: drift_entry_decoder()) {
          Ok(at) -> Ok(at)
          Error(_) -> Error(Nil)
        }
      })
      |> list.fold(0, int.max)
  }
}

fn drift_entry_decoder() -> decode.Decoder(Int) {
  use kind <- decode.field("kind", decode.string)
  use at <- decode.field("at", decode.int)
  case kind {
    "drift" -> decode.success(at)
    _ -> decode.failure(0, "not a drift")
  }
}

pub fn set_name(
  data_dir: String,
  principal: String,
  core: Core,
  name: String,
  at: Int,
) -> Result(Nil, String) {
  let path = core_path(data_dir, principal)
  use _ <- result.try(write_file(
    path,
    encode_core(Core(..core, name: Some(name))),
  ))
  case
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
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> {
      let _ = write_file(path, encode_core(core))
      Error(error)
    }
  }
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
    use prose_sha256 <- decode.optional_field(
      "prose_sha256",
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
      prose_sha256: prose_sha256,
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
      #("prose_sha256", case core.prose_sha256 {
        Some(hash) -> json.string(hash)
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

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn delete_file(path: String) -> Result(Nil, String)

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

@external(erlang, "supernova_self_ffi", "sha256_hex")
fn sha256_hex(value: String) -> String
