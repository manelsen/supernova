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
import supernova/self/reflection
import supernova/self/sampler
import supernova/self/template

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
  extract: fn(String) -> Result(String, String),
) -> Step {
  case core.named(data_dir, principal) {
    True -> AlreadyBorn
    False -> step_unnamed(data_dir, principal, content, now, generate, extract)
  }
}

fn step_unnamed(
  data_dir: String,
  principal: String,
  content: String,
  now: Int,
  generate: fn(String) -> Result(String, String),
  extract: fn(String) -> Result(String, String),
) -> Step {
  case core.load(data_dir, principal) {
    Some(existing) ->
      case existing.name {
        Some(_) -> AlreadyBorn
        None ->
          arrange_name(data_dir, principal, existing, content, now, extract)
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
          case generate_clean_prose(prompt, generate, birth_attempts) {
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
                Ok(_) ->
                  AskName(introduction(prose, generate) <> "\n\n" <> question())
                Error(_) -> BirthFailed
              }
          }
        }
      }
    }
  }
}

/// The first thing the agent says: a short presentation in the core's own
/// voice. The whole core (300 words) read as a monologue from an agent whose
/// core said "falo pouco". Without the prompt or a usable reply, the core's
/// first paragraph presents her.
fn introduction(
  prose: String,
  generate: fn(String) -> Result(String, String),
) -> String {
  let generated = case read_intro_template() {
    Error(_) -> Error(Nil)
    Ok(intro_template) -> {
      let prompt = template.render(intro_template, [#("core", prose)])
      case generate(prompt) {
        Ok(text) ->
          case usable_prose(text) {
            True -> Ok(string.trim(text))
            False -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    }
  }
  case generated {
    Ok(text) -> text
    Error(_) -> first_paragraph(prose)
  }
}

pub fn first_paragraph(prose: String) -> String {
  case string.split(string.trim(prose), "\n\n") {
    [first, ..] -> string.trim(first)
    [] -> prose
  }
}

/// Attempts at a usable core text before giving up on this birth.
const birth_attempts = 3

/// The core is written once and never rewritten, so a broken text is
/// permanent. The first real battery got prose mixing Chinese characters and
/// the model's own reasoning ("Need Portuguese no Chinese") from MiniMax-M3.
fn generate_clean_prose(
  prompt: String,
  generate: fn(String) -> Result(String, String),
  attempts_left: Int,
) -> Result(String, String) {
  case attempts_left <= 0 {
    True -> Error("no usable core text")
    False ->
      case generate(prompt) {
        Error(reason) -> Error(reason)
        Ok(prose) ->
          case usable_prose(prose) {
            True -> Ok(string.trim(prose))
            False -> generate_clean_prose(prompt, generate, attempts_left - 1)
          }
      }
  }
}

/// A core text is usable when it is not empty and has no CJK script (Chinese,
/// Japanese, Korean). It is written in Brazilian Portuguese.
pub fn usable_prose(prose: String) -> Bool {
  string.trim(prose) != ""
  && !list.any(string.to_utf_codepoints(prose), fn(codepoint) {
    is_cjk(string.utf_codepoint_to_int(codepoint))
  })
}

fn is_cjk(code: Int) -> Bool {
  { code >= 0x1100 && code <= 0x11FF }
  || { code >= 0x3000 && code <= 0x30FF }
  || { code >= 0x3130 && code <= 0x318F }
  || { code >= 0xA960 && code <= 0xA97F }
  || { code >= 0xD7B0 && code <= 0xD7FF }
  || { code >= 0x3400 && code <= 0x4DBF }
  || { code >= 0x4E00 && code <= 0x9FFF }
  || { code >= 0xAC00 && code <= 0xD7AF }
  || { code >= 0xF900 && code <= 0xFAFF }
  || { code >= 0xFF00 && code <= 0xFFEF }
}

pub fn question() -> String {
  "Que nome você quer me dar?"
}

pub fn confirm_message(name: String) -> String {
  "Então meu nome é " <> name <> "? Responda sim ou não."
}

/// The agent takes the name as its own; "Prazer, <nome>." read as if it
/// greeted the person by that name, and a persona took it so.
pub fn accepted_message(name: String) -> String {
  name <> ", então. Prazer!"
}

/// A name starts with a capital letter, however the person typed it.
pub fn capitalize_name(name: String) -> String {
  case string.pop_grapheme(name) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    Error(_) -> name
  }
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
  extract: fn(String) -> Result(String, String),
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
                False ->
                  resolve_free_reply(
                    data_dir,
                    principal,
                    existing,
                    pending,
                    content,
                    now,
                    extract,
                  )
              }
          }
        False -> {
          clear_name_pending(data_dir, principal)
          propose_name(data_dir, principal, content, now, extract)
        }
      }
    None -> propose_name(data_dir, principal, content, now, extract)
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

/// A reply to "Então meu nome é X?" that is not a bare yes or no. People
/// answer "Sim, Vera. Fechado." or "sim kkk líquen combina": requiring an
/// exact "sim" looped forever in the first real battery.
/// - the same name again: accept it;
/// - another name: that one becomes the pending candidate;
/// - no name, but the reply opens with a yes ("sim kkk"): accept;
/// - otherwise: not understood.
fn resolve_free_reply(
  data_dir: String,
  principal: String,
  existing: core.Core,
  pending: NamePending,
  content: String,
  now: Int,
  extract: fn(String) -> Result(String, String),
) -> Step {
  case name_candidate(content, extract) {
    Ok(Some(name)) ->
      case same_name(name, pending.candidate) {
        True -> keep_pending_name(data_dir, principal, existing, pending, now)
        False -> pend_name(data_dir, principal, capitalize_name(name), now)
      }
    Ok(None) ->
      case opens_with_affirmation(content) {
        True -> keep_pending_name(data_dir, principal, existing, pending, now)
        False -> {
          clear_name_pending(data_dir, principal)
          NameRejected(rejected_message())
        }
      }
    // The extraction failed: "sim, mas prefiro Ana" must not confirm the
    // pending name. Keep it pending and ask again.
    Error(_) -> NameRejected(rejected_message())
  }
}

fn same_name(a: String, b: String) -> Bool {
  string.lowercase(string.trim(a)) == string.lowercase(string.trim(b))
}

/// The first word of the reply, without punctuation, is a yes.
pub fn opens_with_affirmation(text: String) -> Bool {
  let first =
    normalize_reply(text)
    |> string.replace(",", " ")
    |> string.replace(".", " ")
    |> string.replace("!", " ")
    |> string.split(" ")
    |> list.filter(fn(word) { word != "" })
    |> list.first
  case first {
    Ok(word) -> list.contains(affirmations, word)
    Error(_) -> False
  }
}

/// `Ok(None)`: the reply has no name. `Error`: the extraction failed, and
/// nothing can be said about the reply.
fn name_candidate(
  content: String,
  extract: fn(String) -> Result(String, String),
) -> Result(Option(String), Nil) {
  let trimmed = string.trim(content)
  case !string.contains(trimmed, " ") && core.valid_name(trimmed) {
    True -> Ok(Some(trimmed))
    False -> extract_name(trimmed, extract)
  }
}

fn pend_name(
  data_dir: String,
  principal: String,
  name: String,
  now: Int,
) -> Step {
  case write_name_pending(data_dir, principal, name, now) {
    Ok(_) -> ConfirmName(name)
    Error(_) -> BirthFailed
  }
}

fn propose_name(
  data_dir: String,
  principal: String,
  content: String,
  now: Int,
  extract: fn(String) -> Result(String, String),
) -> Step {
  case name_candidate(content, extract) {
    Ok(Some(name)) -> pend_name(data_dir, principal, capitalize_name(name), now)
    Ok(None) | Error(_) -> NameRejected(rejected_message())
  }
}

fn extract_name(
  reply: String,
  extract: fn(String) -> Result(String, String),
) -> Result(Option(String), Nil) {
  case read_name_template() {
    Error(_) -> Error(Nil)
    Ok(name_template) -> {
      let prompt = template.render(name_template, [#("reply", reply)])
      case extract(prompt) {
        Error(_) -> Error(Nil)
        Ok(raw) ->
          case parse_name(raw) {
            Error(_) -> Error(Nil)
            Ok(None) -> Ok(None)
            Ok(Some(name)) -> {
              let name = string.trim(name)
              // An invalid name is not an absent one: "sim, mas prefiro
              // <nome longo demais>" must not confirm the pending name.
              case core.valid_name(name) {
                True -> Ok(Some(name))
                False -> Error(Nil)
              }
            }
          }
      }
    }
  }
}

fn parse_name(raw: String) -> Result(Option(String), Nil) {
  let decoder = {
    use name <- decode.field("name", decode.optional(decode.string))
    decode.success(name)
  }
  case json.parse(from: reflection.strip_code_fence(raw), using: decoder) {
    Ok(name) -> Ok(name)
    Error(_) -> Error(Nil)
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

/// The name extraction prompt. Without it there is no extraction: the agent
/// asks for just the name instead of guessing.
fn read_name_template() -> Result(String, String) {
  let path = case envoy.get("SUPERNOVA_NAME_PROMPT_PATH") {
    Ok(path) -> path
    Error(_) -> "priv/constellation/name_prompt.md"
  }
  read_file(path)
}

/// The introduction prompt. Without it the core's first paragraph presents
/// the agent.
fn read_intro_template() -> Result(String, String) {
  let path = case envoy.get("SUPERNOVA_INTRO_PROMPT_PATH") {
    Ok(path) -> path
    Error(_) -> "priv/constellation/intro_prompt.md"
  }
  read_file(path)
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
