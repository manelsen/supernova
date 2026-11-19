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
