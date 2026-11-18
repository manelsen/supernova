//// Birth: sample a coherent self, generate its prose, then let the owner name it.

import envoy
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import supernova/self/constellation
import supernova/self/core
import supernova/self/sampler

pub type Step {
  AskName(text: String)
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
          case core.valid_name(content) {
            True -> {
              let name = string.trim(content)
              case core.set_name(data_dir, principal, existing, name, now) {
                Ok(_) -> NameAccepted(name)
                Error(_) -> BirthFailed
              }
            }
            False -> AskName(question())
          }
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
  case constellation.load(core.constellation_path()) {
    Error(_) -> Unavailable
    Ok(loaded) -> {
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
          let prompt = birth_prompt(loaded, sampled)
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
  "Como você quer me chamar?"
}

fn birth_prompt(
  loaded: constellation.Constellation,
  sampled: sampler.Sampled,
) -> String {
  let template = case envoy.get("SUPERNOVA_BIRTH_PROMPT_PATH") {
    Ok(path) -> path
    Error(_) -> "priv/constellation/birth_prompt.md"
  }
  let base = case read_file(template) {
    Ok(text) -> text
    Error(_) -> provisional_prompt()
  }
  let traits =
    sampled.traits
    |> list.map(fn(id) {
      case list.find(loaded.traits, fn(trait) { trait.id == id }) {
        Ok(trait) -> "- " <> trait.id <> ": " <> trait.description
        Error(_) -> "- " <> id
      }
    })
    |> string.join("\n")
  base <> "\n\nTraços sorteados:\n" <> traits
}

fn provisional_prompt() -> String {
  "PROVISÓRIO: escreva, em 2 a 4 frases, o núcleo em prosa desta agente, em primeira pessoa, a partir dos traços abaixo. Não escolha um nome."
}

@external(erlang, "erlang", "phash2")
fn phash(value: String, range: Int) -> Int

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)
