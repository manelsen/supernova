//// Call the persona and judge CLIs.
////
//// No shell is involved: the executable and every argument are passed as a
//// list to `open_port({spawn_executable, ...})`. Persona text and transcripts
//// travel through files, never through argument interpolation.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type CliKind {
  Omp
  Claude
}

pub type CliConfig {
  CliConfig(
    kind: CliKind,
    executable: String,
    model: String,
    max_usd_per_call: Float,
    timeout_seconds: Int,
  )
}

pub type CliResult {
  CliResult(text: String, model: String, cost_usd: Float)
}

pub fn call(
  config: CliConfig,
  system_prompt: String,
  input: String,
  work_dir: String,
  schema: Option(String),
) -> Result(CliResult, String) {
  let assert Ok(_) = ensure_dir(work_dir)
  case config.kind {
    Omp -> call_omp(config, system_prompt, input, work_dir)
    Claude -> call_claude(config, system_prompt, input, work_dir, schema)
  }
}

fn call_omp(
  config: CliConfig,
  system_prompt: String,
  transcript: String,
  work_dir: String,
) -> Result(CliResult, String) {
  let system_path = work_dir <> "/persona_system.md"
  let transcript_path = work_dir <> "/persona_transcript.md"
  use _ <- result.try(write_file(system_path, system_prompt))
  use _ <- result.try(write_file(transcript_path, transcript))
  let args = [
    "-p",
    "--mode",
    "json",
    "--model",
    config.model,
    "--no-session",
    "--no-tools",
    "--no-context-files",
    "--no-skills",
    "--no-rules",
    "--no-lsp",
    "--no-title",
    "--max-cost",
    float_display(config.max_usd_per_call),
    "--max-time",
    int.to_string(config.timeout_seconds),
    "--system-prompt",
    system_path,
    "@" <> transcript_path,
  ]
  use output <- result.try(run(config, args, work_dir))
  parse_omp(output)
}

fn call_claude(
  config: CliConfig,
  system_prompt: String,
  prompt: String,
  work_dir: String,
  schema: Option(String),
) -> Result(CliResult, String) {
  let system_path = work_dir <> "/judge_system.md"
  use _ <- result.try(write_file(system_path, system_prompt))
  let schema_path = work_dir <> "/judge_schema.json"
  use schema_args <- result.try(case schema {
    None -> Ok([])
    Some(text) -> {
      use _ <- result.try(write_file(schema_path, text))
      Ok(["--json-schema", schema_path])
    }
  })
  let args =
    [
      "-p",
      "--model",
      config.model,
      "--output-format",
      "json",
      "--tools",
      "",
      "--strict-mcp-config",
      "--no-session-persistence",
      "--max-budget-usd",
      float_display(config.max_usd_per_call),
      "--system-prompt-file",
      system_path,
    ]
    |> list.append(schema_args)
    |> list.append([prompt])
  use output <- result.try(run(config, args, work_dir))
  parse_claude(output)
}

/// Linux refuses a single argument longer than 128 KiB (MAX_ARG_STRLEN).
/// Long content goes through files; this guard turns a silent exec failure
/// into a clear error.
const max_arg_bytes = 100_000

fn run(
  config: CliConfig,
  args: List(String),
  work_dir: String,
) -> Result(String, String) {
  use _ <- result.try(
    case list.find(args, fn(arg) { string.byte_size(arg) > max_arg_bytes }) {
      Ok(_) -> Error("model call argument too long; pass it through a file")
      Error(_) -> Ok(Nil)
    },
  )
  case
    ffi_run(config.executable, args, work_dir, config.timeout_seconds * 1000)
  {
    Ok(#(0, output)) -> Ok(output)
    Ok(#(3, _output)) -> Error("model call hit the per-call cost cap")
    Ok(#(code, _output)) ->
      Error("model call failed with exit code " <> int.to_string(code))
    Error(_) -> Error("model call timed out")
  }
}

fn float_display(value: Float) -> String {
  string.replace(float.to_string(value), ",", ".")
}

// ============================================================================
// omp JSONL
// ============================================================================

fn parse_omp(output: String) -> Result(CliResult, String) {
  let events =
    output
    |> string.split("\n")
    |> list.filter(fn(line) { string.trim(line) != "" })
  let assistant =
    events
    |> list.filter_map(fn(line) {
      case json.parse(from: line, using: omp_event_decoder()) {
        Ok(Some(event)) -> Ok(event)
        _ -> Error(Nil)
      }
    })
  case assistant {
    [] -> Error("omp output has no assistant message")
    _ -> {
      let last = list.last(assistant)
      let assert Ok(event) = last
      let cost =
        assistant
        |> list.fold(0.0, fn(total, item) { total +. item.cost })
      Ok(CliResult(text: event.text, model: event.model, cost_usd: cost))
    }
  }
}

type OmpEvent {
  OmpEvent(text: String, model: String, cost: Float)
}

fn omp_event_decoder() -> decode.Decoder(Option(OmpEvent)) {
  use kind <- decode.field("type", decode.string)
  case kind == "message_end" {
    False -> decode.success(None)
    True -> {
      use role <- decode.field("message", message_role())
      case role == "assistant" {
        False -> decode.success(None)
        True -> {
          use text <- decode.field("message", message_text())
          use model <- decode.field("message", message_model())
          use cost <- decode.field("message", message_cost())
          decode.success(Some(OmpEvent(text: text, model: model, cost: cost)))
        }
      }
    }
  }
}

fn message_role() -> decode.Decoder(String) {
  use role <- decode.field("role", decode.string)
  decode.success(role)
}

fn message_text() -> decode.Decoder(String) {
  use blocks <- decode.field("content", decode.list(text_block_decoder()))
  decode.success(
    blocks
    |> list.filter_map(fn(item) {
      case item {
        Some(text) -> Ok(text)
        None -> Error(Nil)
      }
    })
    |> string.join(""),
  )
}

fn text_block_decoder() -> decode.Decoder(Option(String)) {
  use kind <- decode.field("type", decode.string)
  case kind == "text" {
    True -> {
      use text <- decode.field("text", decode.string)
      decode.success(Some(text))
    }
    False -> decode.success(None)
  }
}

fn message_model() -> decode.Decoder(String) {
  use model <- decode.field("model", decode.string)
  decode.success(model)
}

fn message_cost() -> decode.Decoder(Float) {
  use usage <- decode.field("usage", usage_cost_decoder())
  decode.success(usage)
}

fn usage_cost_decoder() -> decode.Decoder(Float) {
  use cost <- decode.field("cost", cost_total_decoder())
  decode.success(cost)
}

fn cost_total_decoder() -> decode.Decoder(Float) {
  use total <- decode.field("total", number_decoder())
  decode.success(total)
}

/// JSON numbers may come as `0` or `0.0`; both are a cost.
fn number_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

// ============================================================================
// claude JSON
// ============================================================================

fn parse_claude(output: String) -> Result(CliResult, String) {
  use raw <- result.try(
    json.parse(from: output, using: claude_output_decoder())
    |> result.map_error(fn(_) { "claude output is not JSON" }),
  )
  case raw.is_error {
    True -> Error("claude reported an error")
    False ->
      case raw.subtype == "success" {
        False -> Error("claude subtype: " <> raw.subtype)
        True -> {
          let text = case raw.structured_output {
            Some(value) -> value
            None -> strip_fence(raw.result)
          }
          Ok(CliResult(text: text, model: raw.model, cost_usd: raw.cost_usd))
        }
      }
  }
}

type ClaudeOutput {
  ClaudeOutput(
    is_error: Bool,
    subtype: String,
    result: String,
    structured_output: Option(String),
    model: String,
    cost_usd: Float,
  )
}

fn claude_output_decoder() -> decode.Decoder(ClaudeOutput) {
  use is_error <- decode.optional_field("is_error", False, decode.bool)
  use subtype <- decode.optional_field("subtype", "", decode.string)
  use result <- decode.optional_field("result", "", decode.string)
  use structured_output <- decode.optional_field(
    "structured_output",
    None,
    decode.optional(decode.map(decode.dynamic, json_encode)),
  )
  use model <- decode.optional_field(
    "modelUsage",
    "",
    decode.map(decode.dynamic, first_key),
  )
  use cost_usd <- decode.optional_field("total_cost_usd", 0.0, number_decoder())
  decode.success(ClaudeOutput(
    is_error: is_error,
    subtype: subtype,
    result: result,
    structured_output: structured_output,
    model: model,
    cost_usd: cost_usd,
  ))
}

@external(erlang, "supernova_harness_ffi", "json_first_key")
fn json_first_key(value: Dynamic) -> String

@external(erlang, "supernova_harness_ffi", "json_encode")
fn json_encode(value: Dynamic) -> String

fn first_key(value: Dynamic) -> String {
  json_first_key(value)
}

pub fn strip_fence(text: String) -> String {
  let trimmed = string.trim(text)
  case string.starts_with(trimmed, "```") {
    False -> trimmed
    True -> {
      let without_open =
        trimmed
        |> string.split("\n")
        |> list.drop(1)
        |> string.join("\n")
      case string.contains(without_open, "```") {
        True ->
          without_open
          |> fn(value) { string.split(value, "```") }
          |> list.first
          |> result.unwrap(without_open)
          |> string.trim
        False -> string.trim(without_open)
      }
    }
  }
}

@external(erlang, "supernova_harness_ffi", "run")
fn ffi_run(
  path: String,
  args: List(String),
  cwd: String,
  timeout_ms: Int,
) -> Result(#(Int, String), String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)
