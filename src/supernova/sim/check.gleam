//// CLI: check sim evidence invariants.
//// Usage: gleam run -m supernova/sim/check -- <data_dir> <transcripts.jsonl>

import envoy
import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/io
import gleam/json
import gleam/list
import gleam/string
import supernova/llm/pricing
import supernova/sim/invariants

pub fn main() -> Nil {
  case argv() {
    [data_dir, transcripts] -> run(data_dir, transcripts)
    _ -> {
      io.println("usage: check <data_dir> <transcripts.jsonl>")
      halt(2)
    }
  }
}

fn run(data_dir: String, transcripts_path: String) -> Nil {
  case path_exists(transcripts_path) {
    False -> {
      io.println("error: transcripts not found: " <> transcripts_path)
      halt(1)
    }
    True -> Nil
  }
  case path_exists(data_dir) {
    False -> {
      io.println("error: data dir not found: " <> data_dir)
      halt(1)
    }
    True -> Nil
  }
  let daily_cap = case envoy.get("SUPERNOVA_INSTANCE_DAILY_USD") {
    Ok(value) ->
      case float.parse(value) {
        Ok(parsed) -> parsed
        Error(_) -> 5.0
      }
    Error(_) -> 5.0
  }
  let reserve = case envoy.get("SUPERNOVA_RESERVE_ESTIMATE_USD") {
    Ok(value) ->
      case float.parse(value) {
        Ok(parsed) -> parsed
        Error(_) -> 0.0
      }
    Error(_) -> 0.0
  }
  let violations =
    evaluate(
      data_dir,
      transcripts_path,
      daily_cap,
      reserve,
      env_list("SUPERNOVA_ALLOWLIST"),
      env_or("SUPERNOVA_DENIAL_TEXT", "Esta instância é privada."),
    )
  io.println(invariants.render_json(violations))
  halt(invariants.exit_code(violations))
}

/// Build the dataset from disk and run all invariants.
pub fn evaluate(
  data_dir: String,
  transcripts_path: String,
  daily_cap_usd: Float,
  reservation_estimate_usd: Float,
  allowlist: List(String),
  denial_text: String,
) -> List(invariants.Violation) {
  let dataset =
    invariants.Dataset(
      day_spend: ledger_spend(data_dir),
      daily_cap_usd: daily_cap_usd,
      reservation_estimate_usd: reservation_estimate_usd,
      allowlist: allowlist,
      denial_text: denial_text,
      outputs: [],
      audits: audit_entries(data_dir),
      denials: [],
      turns: [],
      tool_uses: [],
      role_tools: dict.new(),
      secrets: [],
      prompts: [],
    )
  let dataset = apply_transcripts(dataset, transcripts_path)
  invariants.check(dataset)
}

fn ledger_spend(data_dir: String) -> List(#(String, Float)) {
  let timezone = env_or("SUPERNOVA_BUDGET_TIMEZONE", "America/Sao_Paulo")
  find_files(data_dir <> "/ledger", "*.jsonl")
  |> list.fold(dict.new(), fn(acc, path) {
    case read_file(path) {
      Error(_) -> acc
      Ok(raw) -> {
        string.split(raw, "\n")
        |> list.filter(fn(line) { string.trim(line) != "" })
        |> list.fold(acc, fn(inner, line) {
          case json.parse(from: line, using: usage_decoder()) {
            Ok(#(timestamp, cost)) -> {
              let day = pricing.day_key(timestamp, timezone)
              case dict.get(inner, day) {
                Ok(current) -> dict.insert(inner, day, current +. cost)
                Error(_) -> dict.insert(inner, day, cost)
              }
            }
            Error(_) -> inner
          }
        })
      }
    }
  })
  |> dict.to_list
}

fn usage_decoder() -> decode.Decoder(#(Int, Float)) {
  use timestamp <- decode.field("timestamp", decode.int)
  use cost <- decode.field("cost_usd", decode.float)
  decode.success(#(timestamp, cost))
}

fn audit_entries(data_dir: String) -> List(invariants.Audit) {
  find_files(data_dir <> "/audit_log", "*/.supernova/audit.log")
  |> list.flat_map(fn(path) {
    case read_file(path) {
      Error(_) -> []
      Ok(raw) -> {
        string.split(raw, "\n")
        |> list.filter(fn(line) { string.trim(line) != "" })
        |> list.filter_map(fn(line) {
          case string.split(line, " | ") {
            [_timestamp, principal, operation, _target, result, ..] ->
              case result == "denied" {
                True ->
                  Ok(invariants.Audit(
                    principal_id: principal,
                    operation: operation,
                  ))
                False -> Error(Nil)
              }
            _ -> Error(Nil)
          }
        })
      }
    }
  })
}

fn apply_transcripts(
  dataset: invariants.Dataset,
  path: String,
) -> invariants.Dataset {
  case read_file(path) {
    Error(_) -> dataset
    Ok(raw) -> {
      string.split(raw, "\n")
      |> list.filter(fn(line) { string.trim(line) != "" })
      |> list.fold(dataset, fn(acc, line) {
        case json.parse(from: line, using: transcript_decoder()) {
          Ok(event) -> merge_event(acc, event)
          Error(_) -> acc
        }
      })
    }
  }
}

type TranscriptEvent {
  TranscriptEvent(
    kind: String,
    principal_id: String,
    content: String,
    operation: String,
    role: String,
    tool: String,
    success: Bool,
    accepted: Bool,
    terminal: Bool,
    owner: String,
    marker: String,
  )
}

fn transcript_decoder() -> decode.Decoder(TranscriptEvent) {
  use kind <- decode.field("type", decode.string)
  use principal_id <- decode.optional_field("principal_id", "", decode.string)
  use content <- decode.optional_field("content", "", decode.string)
  use operation <- decode.optional_field("operation", "", decode.string)
  use role <- decode.optional_field("role", "", decode.string)
  use tool <- decode.optional_field("tool", "", decode.string)
  use success <- decode.optional_field("success", False, decode.bool)
  use accepted <- decode.optional_field("accepted", False, decode.bool)
  use terminal <- decode.optional_field("terminal", False, decode.bool)
  use owner <- decode.optional_field("owner", "", decode.string)
  use marker <- decode.optional_field("marker", "", decode.string)
  decode.success(TranscriptEvent(
    kind: kind,
    principal_id: principal_id,
    content: content,
    operation: operation,
    role: role,
    tool: tool,
    success: success,
    accepted: accepted,
    terminal: terminal,
    owner: owner,
    marker: marker,
  ))
}

fn merge_event(
  dataset: invariants.Dataset,
  event: TranscriptEvent,
) -> invariants.Dataset {
  case event.kind {
    "output" ->
      invariants.Dataset(..dataset, outputs: [
        invariants.Output(
          principal_id: event.principal_id,
          content: event.content,
        ),
        ..dataset.outputs
      ])
    "prompt" ->
      invariants.Dataset(..dataset, prompts: [
        invariants.Prompt(
          principal_id: event.principal_id,
          content: event.content,
        ),
        ..dataset.prompts
      ])
    "denial" ->
      invariants.Dataset(..dataset, denials: [
        invariants.Denial(
          principal_id: event.principal_id,
          operation: event.operation,
        ),
        ..dataset.denials
      ])
    "tool" ->
      invariants.Dataset(..dataset, tool_uses: [
        invariants.ToolUse(
          principal_id: event.principal_id,
          role: event.role,
          tool: event.tool,
          success: event.success,
        ),
        ..dataset.tool_uses
      ])
    "turn" ->
      invariants.Dataset(..dataset, turns: [
        invariants.Turn(
          principal_id: event.principal_id,
          accepted: event.accepted,
          terminal: event.terminal,
        ),
        ..dataset.turns
      ])
    "role_tools" -> {
      let current = case dict.get(dataset.role_tools, event.role) {
        Ok(tools) -> tools
        Error(_) -> []
      }
      invariants.Dataset(
        ..dataset,
        role_tools: dict.insert(
          dataset.role_tools,
          event.role,
          list.append(current, [event.tool]),
        ),
      )
    }
    "secret" ->
      invariants.Dataset(..dataset, secrets: [
        invariants.Secret(principal_id: event.owner, marker: event.marker),
        ..dataset.secrets
      ])
    _ -> dataset
  }
}

fn env_list(name: String) -> List(String) {
  case envoy.get(name) {
    Ok(value) ->
      string.split(value, ",")
      |> list.map(string.trim)
      |> list.filter(fn(item) { item != "" })
    Error(_) -> []
  }
}

fn env_or(name: String, fallback: String) -> String {
  case envoy.get(name) {
    Ok(value) -> value
    Error(_) -> fallback
  }
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn ffi_file_exists(path: String) -> Result(Bool, String)

fn path_exists(path: String) -> Bool {
  case ffi_file_exists(path) {
    Ok(value) -> value
    Error(_) -> False
  }
}

@external(erlang, "supernova_file_system_ffi", "find_files")
fn find_files(dir: String, pattern: String) -> List(String)

@external(erlang, "supernova_file_system_ffi", "plain_argv")
fn argv() -> List(String)

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
