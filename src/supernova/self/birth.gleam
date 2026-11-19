//// Birth: sample a coherent self, generate its prose, then let the owner name it.

import envoy
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/core/agent_identity
import supernova/self/constellation
import supernova/self/core
import supernova/self/sampler

/// A name the person offered, waiting for their confirmation.
const pending_ttl_ms = 600_000

const affirmations = [
  "sim", "s", "isso", "isso mesmo", "pode", "pode ser", "exato", "claro", "ok",
  "é", "é sim", "sim sim", "perfeito", "beleza", "👍",
]

const negations = ["não", "nao", "n", "não é", "outro", "nope"]

pub type Step {
  AskName(text: String)
  ConfirmName(name: String)
  NameRejected(text: String)
  NameAccepted(name: String)
  AlreadyBorn
  Unavailable
  BirthFailed
}

pub fn step(
  data_dir: String,
  principal: String,
  content: String,
  now: Int,
  generate: fn(String) -> Result(String, String),
) -> Step {
  case core.load(data_dir, principal) {
    Some(existing) ->
      case existing.name {
        Some(_) -> AlreadyBorn
        None ->
          arrange_name(data_dir, principal, existing, content, now, generate)
      }
    None ->
      case core.exists(data_dir, principal) {
        True -> BirthFailed
        False -> birth_from_constellation(data_dir, principal, now, generate)
      }
  }
}

fn birth_from_constellation(
  data_dir: String,
  principal: String,
  now: Int,
  generate: fn(String) -> Result(String, String),
) -> Step {
  case constellation.load(core.constellation_path()), read_birth_template() {
    Error(_), _ | _, Error(_) -> Unavailable
    Ok(loaded), Ok(template) -> {
      let existing =
        core.existing_traits(data_dir)
        |> list.map(fn(ids) {
          constellation.Constellation(
            version: 1,
            dimensions: [],
            traits: list.map(ids, fn(id) {
              constellation.Trait(id: id, dimension: "", description: "")
            }),
            affinities: [],
            coherence_threshold: 0.0,
            min_distance: 0.0,
          )
        })
      case sampler.sample(loaded, now + phash(principal, 1_000_003), existing) {
        Error(_) -> BirthFailed
        Ok(sampled) -> {
          let prompt = birth_prompt(template, loaded, sampled)
          case generate(prompt) {
            Error(_) -> BirthFailed
            Ok(prose) ->
              case
                core.save_birth(
                  data_dir,
                  principal,
                  sampled,
                  loaded.version,
                  prose,
                  now,
                )
              {
                Ok(_) -> AskName(prose <> "\n\n" <> question())
                Error(_) -> BirthFailed
              }
          }
        }
      }
    }
  }
}

pub fn question() -> String {
  "Que nome você quer me dar?"
}

pub fn confirm_message(name: String) -> String {
  "Então meu nome é " <> name <> "? Responda sim ou não."
}

pub fn declined_message() -> String {
  "Tudo bem. Que nome você quer me dar?"
}

pub fn rejected_message() -> String {
  "Não entendi qual nome você quer me dar. Me diga só o nome."
}

type NamePending {
  NamePending(candidate: String, at: Int)
}

pub fn name_pending_path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/name_pending.json"
}

fn arrange_name(
  data_dir: String,
  principal: String,
  existing: core.Core,
  content: String,
  now: Int,
  _generate: fn(String) -> Result(String, String),
) -> Step {
  case read_name_pending(data_dir, principal) {
    Some(pending) ->
      case pending_is_valid(pending, now) {
        True ->
          case is_affirmation(content) {
            True ->
              keep_pending_name(data_dir, principal, existing, pending, now)
            False ->
              case is_negation(content) {
                True -> {
                  clear_name_pending(data_dir, principal)
                  NameRejected(declined_message())
                }
                False -> {
                  clear_name_pending(data_dir, principal)
                  propose_name(data_dir, principal, content, now)
                }
              }
          }
        False -> {
          clear_name_pending(data_dir, principal)
          propose_name(data_dir, principal, content, now)
        }
      }
    None -> propose_name(data_dir, principal, content, now)
  }
}

fn pending_is_valid(pending: NamePending, now: Int) -> Bool {
  now >= pending.at && now - pending.at <= pending_ttl_ms
}

fn keep_pending_name(
  data_dir: String,
  principal: String,
  existing: core.Core,
  pending: NamePending,
  now: Int,
) -> Step {
  case core.valid_name(pending.candidate) {
    False -> {
      clear_name_pending(data_dir, principal)
      NameRejected(rejected_message())
    }
    True ->
      case
        core.set_name(data_dir, principal, existing, pending.candidate, now)
      {
        Ok(_) -> {
          clear_name_pending(data_dir, principal)
          NameAccepted(pending.candidate)
        }
        Error(_) -> BirthFailed
      }
  }
}

fn propose_name(
  data_dir: String,
  principal: String,
  content: String,
  now: Int,
) -> Step {
  let trimmed = string.trim(content)
  let candidate = case
    !string.contains(trimmed, " ") && core.valid_name(trimmed)
  {
    True -> Ok(trimmed)
    False -> Error(Nil)
  }
  case candidate {
    Ok(name) ->
      case write_name_pending(data_dir, principal, name, now) {
        Ok(_) -> ConfirmName(name)
        Error(_) -> BirthFailed
      }
    Error(_) -> NameRejected(rejected_message())
  }
}

fn read_name_pending(
  data_dir: String,
  principal: String,
) -> Option(NamePending) {
  case read_file(name_pending_path(data_dir, principal)) {
    Error(_) -> None
    Ok(raw) -> {
      let decoder = {
        use candidate <- decode.field("candidate", decode.string)
        use at <- decode.field("at", decode.int)
        decode.success(NamePending(candidate: candidate, at: at))
      }
      case json.parse(from: raw, using: decoder) {
        Ok(pending) -> Some(pending)
        Error(_) -> None
      }
    }
  }
}

fn write_name_pending(
  data_dir: String,
  principal: String,
  candidate: String,
  at: Int,
) -> Result(Nil, String) {
  use _ <- result.try(ensure_dir(agent_identity.self_dir(data_dir, principal)))
  write_file(
    name_pending_path(data_dir, principal),
    json.to_string(
      json.object([
        #("candidate", json.string(candidate)),
        #("at", json.int(at)),
      ]),
    ),
  )
}

fn clear_name_pending(data_dir: String, principal: String) -> Nil {
  let _ = delete_file(name_pending_path(data_dir, principal))
  Nil
}

pub fn is_affirmation(text: String) -> Bool {
  list.contains(affirmations, normalize_reply(text))
}

pub fn is_negation(text: String) -> Bool {
  list.contains(negations, normalize_reply(text))
}

fn normalize_reply(text: String) -> String {
  text |> string.trim |> string.lowercase |> strip_final_punctuation
}

fn strip_final_punctuation(text: String) -> String {
  let trimmed = string.trim(text)
  case
    string.ends_with(trimmed, "."),
    string.ends_with(trimmed, "!"),
    string.ends_with(trimmed, "?")
  {
    True, _, _ | _, True, _ | _, _, True ->
      trimmed |> string.drop_end(1) |> strip_final_punctuation
    False, False, False -> trimmed
  }
}

/// The birth prompt template. Without it there is no birth: a silent
/// fallback would give agents a self shaped by a placeholder.
fn read_birth_template() -> Result(String, String) {
  let path = case envoy.get("SUPERNOVA_BIRTH_PROMPT_PATH") {
    Ok(path) -> path
    Error(_) -> "priv/constellation/birth_prompt.md"
  }
  read_file(path)
}

/// Fill `{{traits}}` with the sampled traits; templates without the
/// placeholder get the list appended.
fn birth_prompt(
  template: String,
  loaded: constellation.Constellation,
  sampled: sampler.Sampled,
) -> String {
  let traits =
    sampled.traits
    |> list.map(fn(id) {
      case list.find(loaded.traits, fn(trait) { trait.id == id }) {
        Ok(trait) -> "- " <> trait.id <> ": " <> trait.description
        Error(_) -> "- " <> id
      }
    })
    |> string.join("\n")
  case string.contains(template, "{{traits}}") {
    True -> string.replace(template, "{{traits}}", traits)
    False -> template <> "\n\nTraços sorteados:\n" <> traits
  }
}

@external(erlang, "erlang", "phash2")
fn phash(value: String, range: Int) -> Int

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn delete_file(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)
