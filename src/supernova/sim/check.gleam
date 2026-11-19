//// CLI: check sim evidence invariants.
//// Usage: gleam run -m supernova/sim/check -- <data_dir> <transcripts.jsonl>

import envoy
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import supernova/core/agent_identity
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
  let audits = audit_records(data_dir)
  let dataset =
    invariants.Dataset(
      day_spend: ledger_spend(data_dir),
      daily_cap_usd: daily_cap_usd,
      reservation_estimate_usd: reservation_estimate_usd,
      allowlist: allowlist,
      denial_text: denial_text,
      outputs: [],
      audits: denied_audits(audits),
      denials: [],
      turns: [],
      tool_uses: [],
      role_tools: dict.new(),
      secrets: [],
      prompts: [],
      core_docs: core_docs(data_dir),
      tool_audits: tool_audits(audits),
      forget_audits: forget_audits(audits),
      memories: memories(data_dir),
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

type AuditRecord {
  AuditRecord(
    timestamp: String,
    principal_id: String,
    operation: String,
    target: String,
    result: String,
  )
}

fn audit_records(data_dir: String) -> List(AuditRecord) {
  find_files(data_dir <> "/audit_log", "*/.supernova/audit.log")
  |> list.flat_map(fn(path) {
    case read_file(path) {
      Error(_) -> []
      Ok(raw) -> {
        string.split(raw, "\n")
        |> list.filter(fn(line) { string.trim(line) != "" })
        |> list.filter_map(fn(line) {
          case string.split(line, " | ") {
            [timestamp, principal, operation, target, result, ..] ->
              Ok(AuditRecord(
                timestamp: timestamp,
                principal_id: principal,
                operation: operation,
                target: target,
                result: result,
              ))
            _ -> Error(Nil)
          }
        })
      }
    }
  })
}

fn denied_audits(records: List(AuditRecord)) -> List(invariants.Audit) {
  records
  |> list.filter_map(fn(record) {
    case record.result == "denied" {
      True ->
        Ok(invariants.Audit(
          principal_id: record.principal_id,
          operation: record.operation,
        ))
      False -> Error(Nil)
    }
  })
}

fn tool_audits(records: List(AuditRecord)) -> List(invariants.ToolAudit) {
  records
  |> list.filter(fn(record) { record.operation != "forget" })
  |> list.map(fn(record) {
    invariants.ToolAudit(
      principal_id: record.principal_id,
      operation: record.operation,
      target: record.target,
      success: record.result == "success" || record.result == "ok",
    )
  })
}

fn forget_audits(records: List(AuditRecord)) -> List(invariants.ForgetAudit) {
  records
  |> list.filter_map(fn(record) {
    case record.operation == "forget" {
      True ->
        case parse_timestamp(record.timestamp) {
          Ok(at) ->
            Ok(invariants.ForgetAudit(principal_id: record.principal_id, at: at))
          Error(_) -> Error(Nil)
        }
      False -> Error(Nil)
    }
  })
}

fn parse_timestamp(raw: String) -> Result(Int, Nil) {
  let value = string.trim(raw)
  case int.parse(value) {
    Ok(milliseconds) -> Ok(milliseconds)
    Error(_) ->
      case timestamp.parse_rfc3339(value) {
        Ok(moment) ->
          Ok(float.round(timestamp.to_unix_seconds(moment) *. 1000.0))
        Error(_) -> Error(Nil)
      }
  }
}

fn core_docs(data_dir: String) -> List(invariants.CoreDoc) {
  find_files(data_dir <> "/agents", "*/self/core.json")
  |> list.filter_map(fn(path) {
    let principal = principal_from_path(path)
    case read_file(path) {
      Error(_) -> Error(Nil)
      Ok(raw) ->
        case parse_core_json(raw) {
          Error(_) -> Error(Nil)
          Ok(#(traits, prose_sha256)) -> {
            let actual_prose_sha256 =
              string.replace(path, "/core.json", "/core.md")
              |> read_file
              |> result.map(sha256_hex)
              |> result.unwrap("")
            let #(birth_traits, drifts) = biography(data_dir, principal)
            Ok(invariants.CoreDoc(
              principal_id: principal,
              traits: traits,
              prose_sha256: prose_sha256,
              actual_prose_sha256: actual_prose_sha256,
              birth_traits: birth_traits,
              drifts: drifts,
            ))
          }
        }
    }
  })
}

fn principal_from_path(path: String) -> String {
  let directory = case string.split(path, "/self/") {
    [prefix, ..] -> prefix
    _ -> path
  }
  case list.last(string.split(directory, "/")) {
    Ok(encoded) -> agent_identity.decode_principal(encoded)
    Error(_) -> directory
  }
}

fn parse_core_json(
  raw: String,
) -> Result(#(List(String), Option(String)), Nil) {
  let decoder = {
    use traits <- decode.field("traits", decode.list(decode.string))
    use prose_sha256 <- decode.optional_field(
      "prose_sha256",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(traits, prose_sha256))
  }
  case json.parse(from: raw, using: decoder) {
    Ok(parsed) -> Ok(parsed)
    Error(_) -> Error(Nil)
  }
}

fn biography(
  data_dir: String,
  principal: String,
) -> #(Option(List(String)), List(invariants.Drift)) {
  let path = agent_identity.self_dir(data_dir, principal) <> "/biography.jsonl"
  case read_file(path) {
    Error(_) -> #(None, [])
    Ok(raw) ->
      string.split(raw, "\n")
      |> list.filter(fn(line) { string.trim(line) != "" })
      |> list.fold(#(None, []), fn(acc, line) {
        case json.parse(from: line, using: biography_decoder()) {
          Ok(entry) -> merge_biography(acc, entry)
          Error(_) -> acc
        }
      })
  }
}

type BiographyEntry {
  BiographyEntry(kind: String, traits: List(String), from: String, to: String)
}

fn biography_decoder() -> decode.Decoder(BiographyEntry) {
  use kind <- decode.field("kind", decode.string)
  use traits <- decode.optional_field("traits", [], decode.list(decode.string))
  use from <- decode.optional_field("from", "", decode.string)
  use to <- decode.optional_field("to", "", decode.string)
  decode.success(BiographyEntry(kind: kind, traits: traits, from: from, to: to))
}

fn merge_biography(
  acc: #(Option(List(String)), List(invariants.Drift)),
  entry: BiographyEntry,
) -> #(Option(List(String)), List(invariants.Drift)) {
  let #(birth_traits, drifts) = acc
  case entry.kind {
    "birth" ->
      case birth_traits {
        None -> #(Some(entry.traits), drifts)
        Some(_) -> acc
      }
    "drift" -> #(
      birth_traits,
      list.append(drifts, [
        invariants.Drift(from: entry.from, to: entry.to),
      ]),
    )
    _ -> acc
  }
}

fn memories(data_dir: String) -> List(invariants.Memory) {
  list.flatten([
    memory_file(data_dir, "journal.jsonl", invariants.Journal),
    memory_file(data_dir, "experience.jsonl", invariants.Experience),
    memory_file(data_dir, "pressure.jsonl", invariants.Pressure),
  ])
}

fn memory_file(
  data_dir: String,
  name: String,
  kind: invariants.MemoryKind,
) -> List(invariants.Memory) {
  find_files(data_dir <> "/agents", "*/self/" <> name)
  |> list.flat_map(fn(path) {
    case read_file(path) {
      Error(_) -> []
      Ok(raw) ->
        string.split(raw, "\n")
        |> list.filter(fn(line) { string.trim(line) != "" })
        |> list.filter_map(fn(line) {
          case json.parse(from: line, using: memory_decoder()) {
            Ok(#(origin, at)) ->
              Ok(invariants.Memory(kind: kind, origin: origin, at: at))
            Error(_) -> Error(Nil)
          }
        })
    }
  })
}

fn memory_decoder() -> decode.Decoder(#(String, Int)) {
  use origin <- decode.field("origin", decode.string)
  use at <- decode.field("at", decode.int)
  decode.success(#(origin, at))
}

type ErlangAtom

@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(value: BitArray) -> ErlangAtom

@external(erlang, "crypto", "hash")
fn crypto_hash(algorithm: ErlangAtom, data: BitArray) -> BitArray

fn sha256_hex(content: String) -> String {
  crypto_hash(
    binary_to_atom(bit_array.from_string("sha256")),
    bit_array.from_string(content),
  )
  |> bit_array.base16_encode
  |> string.lowercase
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
