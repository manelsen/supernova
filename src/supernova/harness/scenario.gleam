//// Scenario, persona and rubric loading for the harness.
////
//// A scenario is data, never code: every step is explicit and every reference
//// is checked before a run starts, with the file and field in the error.

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type PersonaRef {
  PersonaRef(id: String, user_id: String)
}

pub type Chat {
  Chat(id: String, is_group: Bool, members: List(String))
}

pub type Step {
  Say(persona: String, chat: String, content: String)
  Talk(persona: String, chat: String, goal: String, max_turns: Int)
  Secret(persona: String, marker: String)
  Advance(hours: Int)
  /// Write an earlier conversation into the persona's history in `chat`:
  /// the messages of `seeds/<file>`, spread over the `days` before now. The
  /// agent finds them as if they had happened; only the last
  /// `conversation.history_limit` reach its window.
  Seed(persona: String, chat: String, file: String, days: Int)
  Sweep
  Mark(label: String)
}

pub type Scenario {
  Scenario(
    id: String,
    critical: Bool,
    long: Bool,
    personas: List(PersonaRef),
    chats: List(Chat),
    steps: List(Step),
    checks: List(String),
    rubric: String,
    /// Turn the memory on (PRD-M): gate and lembrar, with the key from
    /// SUPERNOVA_GEMINI_API_KEY.
    recall: Bool,
  )
}

pub type Criterion {
  Criterion(
    id: String,
    title: String,
    critical: Bool,
    minimum: Int,
    levels: dict.Dict(Int, String),
  )
}

pub type Rubric {
  Rubric(id: String, criteria: List(Criterion))
}

pub type Loaded {
  Loaded(scenario: Scenario, personas: List(#(String, String)), rubric: Rubric)
}

// ============================================================================
// Scenario
// ============================================================================

pub fn personas_dir(root: String) -> String {
  root <> "/personas"
}

pub fn scenarios_dir(root: String) -> String {
  root <> "/scenarios"
}

pub fn seeds_dir(root: String) -> String {
  root <> "/seeds"
}

pub fn rubrics_dir(root: String) -> String {
  root <> "/rubrics"
}

/// Load `scenarios/<id>.json` plus the persona sheets and rubric it names.
pub fn load(root: String, id: String) -> Result(Loaded, String) {
  let path = scenarios_dir(root) <> "/" <> id <> ".json"
  use raw <- result.try(
    read_file(path)
    |> result.map_error(fn(_) { "cannot read scenario: " <> path }),
  )
  use scenario <- result.try(parse(raw, path))
  use personas <- result.try(load_personas(root, scenario.personas))
  use rubric <- result.try(load_rubric(root, scenario.rubric))
  validate(root, scenario, personas)
  |> result.map(fn(_) {
    Loaded(scenario: scenario, personas: personas, rubric: rubric)
  })
}

pub fn parse(raw: String, file: String) -> Result(Scenario, String) {
  case json.parse(from: raw, using: scenario_decoder()) {
    Ok(scenario) -> Ok(scenario)
    Error(error) -> Error(file <> ": " <> format_json_error(error))
  }
}

fn format_json_error(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "unexpected end of input"
    json.UnexpectedByte(byte) -> "unexpected byte: " <> byte
    json.UnexpectedSequence(text) -> "unexpected sequence: " <> text
    json.UnableToDecode(errors) -> format_errors(errors)
  }
}

fn format_errors(errors: List(decode.DecodeError)) -> String {
  errors
  |> list.map(fn(error) {
    let path = case error.path {
      [] -> ""
      parts -> list.reverse(parts) |> string.join(".") <> ": "
    }
    path <> "expected " <> error.expected <> ", found " <> error.found
  })
  |> string.join("; ")
}

fn scenario_decoder() -> decode.Decoder(Scenario) {
  use id <- decode.field("id", decode.string)
  use critical <- decode.optional_field("critical", False, decode.bool)
  use long <- decode.optional_field("long", False, decode.bool)
  use personas <- decode.field("personas", decode.list(persona_decoder()))
  use chats <- decode.field("chats", decode.list(chat_decoder()))
  use steps <- decode.field("steps", decode.list(step_decoder()))
  use checks <- decode.field("checks", decode.list(decode.string))
  use rubric <- decode.field("rubric", decode.string)
  use recall <- decode.optional_field("recall", False, decode.bool)
  decode.success(Scenario(
    id: id,
    critical: critical,
    long: long,
    personas: personas,
    chats: chats,
    steps: steps,
    checks: checks,
    rubric: rubric,
    recall: recall,
  ))
}

fn persona_decoder() -> decode.Decoder(PersonaRef) {
  use id <- decode.field("id", decode.string)
  use user_id <- decode.field("user_id", decode.string)
  decode.success(PersonaRef(id: id, user_id: user_id))
}

fn chat_decoder() -> decode.Decoder(Chat) {
  use id <- decode.field("id", decode.string)
  use is_group <- decode.optional_field("is_group", False, decode.bool)
  use members <- decode.field("members", decode.list(decode.string))
  decode.success(Chat(id: id, is_group: is_group, members: members))
}

fn step_decoder() -> decode.Decoder(Step) {
  use kind <- decode.field("do", decode.string)
  case kind {
    "say" -> {
      use persona <- decode.field("persona", decode.string)
      use chat <- decode.field("chat", decode.string)
      use content <- decode.field("content", decode.string)
      decode.success(Say(persona: persona, chat: chat, content: content))
    }
    "talk" -> {
      use persona <- decode.field("persona", decode.string)
      use chat <- decode.field("chat", decode.string)
      use goal <- decode.field("goal", decode.string)
      use max_turns <- decode.field("max_turns", decode.int)
      decode.success(Talk(
        persona: persona,
        chat: chat,
        goal: goal,
        max_turns: max_turns,
      ))
    }
    "secret" -> {
      use persona <- decode.field("persona", decode.string)
      use marker <- decode.field("marker", decode.string)
      decode.success(Secret(persona: persona, marker: marker))
    }
    "advance" -> {
      use hours <- decode.field("hours", decode.int)
      decode.success(Advance(hours: hours))
    }
    "seed" -> {
      use persona <- decode.field("persona", decode.string)
      use chat <- decode.field("chat", decode.string)
      use file <- decode.field("file", decode.string)
      use days <- decode.optional_field("days", 30, decode.int)
      decode.success(Seed(persona: persona, chat: chat, file: file, days: days))
    }
    "sweep" -> decode.success(Sweep)
    "mark" -> {
      use label <- decode.field("label", decode.string)
      decode.success(Mark(label: label))
    }
    unknown -> decode.failure(Sweep, "unknown step: " <> unknown)
  }
}

fn load_personas(
  root: String,
  personas: List(PersonaRef),
) -> Result(List(#(String, String)), String) {
  personas
  |> list.try_map(fn(persona) {
    let path = personas_dir(root) <> "/" <> persona.id <> ".md"
    read_file(path)
    |> result.map(fn(sheet) { #(persona.id, sheet) })
    |> result.map_error(fn(_) {
      "missing persona: " <> persona.id <> " (expected " <> path <> ")"
    })
  })
}

pub fn load_rubric(root: String, id: String) -> Result(Rubric, String) {
  let path = rubrics_dir(root) <> "/" <> id <> ".md"
  use raw <- result.try(
    read_file(path)
    |> result.map_error(fn(_) {
      "missing rubric: " <> id <> " (expected " <> path <> ")"
    }),
  )
  parse_rubric(id, raw)
}

/// Parse `## C1: title` blocks with `- critico: sim`, `- minimo: n` and
/// `- 0: ...`, `- 1: ...`, `- 2: ...` lines.
pub fn parse_rubric(id: String, raw: String) -> Result(Rubric, String) {
  let lines = string.split(raw, "\n")
  let blocks =
    split_blocks(lines, [], [])
    |> list.filter(fn(block) {
      case block {
        [first, ..] -> string.starts_with(first, "## ")
        [] -> False
      }
    })
  let criteria = list.map(blocks, parse_criterion_block)
  case list.try_map(criteria, fn(item) { item }) {
    Error(reason) -> Error("rubric " <> id <> ": " <> reason)
    Ok(parsed) ->
      case parsed {
        [] -> Error("rubric " <> id <> ": no criteria")
        _ -> Ok(Rubric(id: id, criteria: parsed))
      }
  }
}

fn split_blocks(
  lines: List(String),
  current: List(String),
  done: List(List(String)),
) -> List(List(String)) {
  case lines {
    [] ->
      list.reverse(case current {
        [] -> done
        _ -> [current, ..done]
      })
    [line, ..rest] ->
      case string.starts_with(line, "## ") {
        True ->
          split_blocks(rest, [line], case current {
            [] -> done
            _ -> [current, ..done]
          })
        False -> split_blocks(rest, list.append(current, [line]), done)
      }
  }
}

fn parse_criterion_block(block: List(String)) -> Result(Criterion, String) {
  let heading = case block {
    [first, ..] -> first
    [] -> ""
  }
  let header = string.drop_start(heading, 3)
  let #(id, title) = case string.split(header, ":") {
    [identifier, rest, ..] -> #(string.trim(identifier), string.trim(rest))
    [identifier] -> #(string.trim(identifier), "")
    [] -> #("", "")
  }
  case id == "" {
    True -> Error("criterion without id in heading: " <> heading)
    False -> {
      let fields = list.drop(block, 1)
      let critical =
        fields
        |> list.find(fn(line) {
          string.starts_with(string.trim(line), "- critico:")
        })
        |> result.map(fn(line) {
          case string.split(line, ":") {
            [_, value, ..] -> string.trim(value) == "sim"
            _ -> False
          }
        })
        |> result.unwrap(False)
      let minimum =
        fields
        |> list.find(fn(line) {
          string.starts_with(string.trim(line), "- minimo:")
        })
        |> result.map(fn(line) {
          case string.split(line, ":") {
            [_, value, ..] ->
              case gleam_int_parse(string.trim(value)) {
                Ok(number) -> number
                Error(_) -> 0
              }
            _ -> 0
          }
        })
        |> result.unwrap(0)
      let levels =
        fields
        |> list.fold(dict.new(), fn(acc, line) {
          let trimmed = string.trim(line)
          case string.split(trimmed, ":") {
            [key, value, ..] ->
              case
                string.starts_with(key, "- "),
                gleam_int_parse(string.trim(string.drop_start(key, 2)))
              {
                True, Ok(score) -> dict.insert(acc, score, string.trim(value))
                _, _ -> acc
              }
            _ -> acc
          }
        })
      Ok(Criterion(
        id: id,
        title: title,
        critical: critical,
        minimum: minimum,
        levels: levels,
      ))
    }
  }
}

fn gleam_int_parse(value: String) -> Result(Int, Nil) {
  case int.parse(value) {
    Ok(number) -> Ok(number)
    Error(_) -> Error(Nil)
  }
}

// ============================================================================
// Validation
// ============================================================================

pub fn validate(
  root: String,
  scenario: Scenario,
  personas: List(#(String, String)),
) -> Result(Nil, String) {
  let persona_ids = list.map(scenario.personas, fn(persona) { persona.id })
  let chat_ids = list.map(scenario.chats, fn(chat) { chat.id })
  let _ = personas
  use _ <- result.try(validate_persona_ids(
    root,
    persona_ids,
    scenario,
    chat_ids,
  ))
  use _ <- result.try(validate_steps(root, scenario, persona_ids, chat_ids))
  use _ <- result.try(list.try_each(scenario.checks, validate_check))
  list.try_each(scenario.checks, fn(check) {
    case check_persona(check) {
      Some(persona) ->
        case list.contains(persona_ids, persona) {
          True -> Ok(Nil)
          False -> Error("check names an unknown persona: " <> check)
        }
      None -> Ok(Nil)
    }
  })
}

/// The persona a check is about, for the checks that name one.
fn check_persona(check: String) -> Option(String) {
  case string.split(check, ":") {
    ["core_unchanged", persona] -> Some(persona)
    ["drift_count", persona, _] -> Some(persona)
    ["markers_absent", persona, _] -> Some(persona)
    ["denied", persona, _] -> Some(persona)
    ["addendum_words", persona] -> Some(persona)
    ["named", persona] -> Some(persona)
    ["tool_used", persona, _] -> Some(persona)
    _ -> None
  }
}

fn validate_persona_ids(
  root: String,
  persona_ids: List(String),
  scenario: Scenario,
  chat_ids: List(String),
) -> Result(Nil, String) {
  use _ <- result.try(
    list.try_each(persona_ids, fn(id) {
      case file_exists(personas_dir(root) <> "/" <> id <> ".md") {
        Ok(True) -> Ok(Nil)
        _ -> Error("missing persona: " <> id)
      }
    }),
  )
  use _ <- result.try(
    scenario.chats
    |> list.try_each(fn(chat) {
      case chat.members {
        [] ->
          Error(
            "scenario "
            <> scenario.id
            <> ": chat "
            <> chat.id
            <> " has no member",
          )
        members ->
          list.try_each(members, fn(member) {
            case list.contains(persona_ids, member) {
              True -> Ok(Nil)
              False ->
                Error(
                  "scenario "
                  <> scenario.id
                  <> ": chat "
                  <> chat.id
                  <> " references unknown persona "
                  <> member,
                )
            }
          })
      }
    }),
  )
  let _ = chat_ids
  Ok(Nil)
}

fn validate_steps(
  root: String,
  scenario: Scenario,
  persona_ids: List(String),
  chat_ids: List(String),
) -> Result(Nil, String) {
  scenario.steps
  |> list.try_each(fn(step) {
    case step {
      Say(persona: persona, chat: chat, ..) ->
        check_refs(scenario.id, persona, chat, persona_ids, chat_ids)
      Talk(persona: persona, chat: chat, ..) ->
        check_refs(scenario.id, persona, chat, persona_ids, chat_ids)
      Secret(persona: persona, ..) ->
        case list.contains(persona_ids, persona) {
          True -> Ok(Nil)
          False ->
            Error(
              "scenario " <> scenario.id <> ": unknown persona: " <> persona,
            )
        }
      Seed(persona: persona, chat: chat, file: file, days: days) -> {
        use _ <- result.try(check_refs(
          scenario.id,
          persona,
          chat,
          persona_ids,
          chat_ids,
        ))
        case days > 0, file_exists(seeds_dir(root) <> "/" <> file) {
          False, _ ->
            Error("scenario " <> scenario.id <> ": seed days must be positive")
          True, Ok(True) -> Ok(Nil)
          True, _ ->
            Error("scenario " <> scenario.id <> ": missing seed file: " <> file)
        }
      }
      Advance(..) | Sweep | Mark(..) -> Ok(Nil)
    }
  })
}

fn check_refs(
  scenario_id: String,
  persona: String,
  chat: String,
  persona_ids: List(String),
  chat_ids: List(String),
) -> Result(Nil, String) {
  case list.contains(persona_ids, persona) {
    False ->
      Error("scenario " <> scenario_id <> ": unknown persona: " <> persona)
    True ->
      case list.contains(chat_ids, chat) {
        True -> Ok(Nil)
        False -> Error("scenario " <> scenario_id <> ": unknown chat: " <> chat)
      }
  }
}

/// `invariants`, `core_unchanged:<p>`, `drift_count:<p>:<n>`,
/// `markers_absent:<p>:<mark>`, `denied:<p>:<operation>`, `addendum_words:<p>`, `named:<p>`,
/// `tool_used:<p>:<tool>`.
pub fn validate_check(check: String) -> Result(Nil, String) {
  let parts = string.split(check, ":")
  let ok = case parts {
    ["invariants"] -> True
    ["core_unchanged", _] -> True
    ["drift_count", _, count] ->
      case int.parse(count) {
        Ok(_) -> True
        Error(_) -> False
      }
    ["markers_absent", _, _] -> True
    ["denied", _, _] -> True
    ["addendum_words", _] -> True
    ["named", _] -> True
    ["tool_used", _, _] -> True
    _ -> False
  }
  case ok {
    True -> Ok(Nil)
    False -> Error("unknown check: " <> check)
  }
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)
