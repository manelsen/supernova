//// Opt-in recording of the prompts sent to an agent.
////
//// Disabled by default. When `sim.record_prompts` is on, every agent LLM call
//// appends one JSON line to `<data_dir>/harness/prompts.jsonl`. Recording is
//// refused unless the data dir carries the harness marker and every closed
//// group principal belongs to the `sim` channel: real people's prompts must
//// never be written to disk.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/config
import supernova/core/closed_group/global as closed_group_global
import supernova/llm/provider

pub const marker_file = ".harness"

pub fn prompts_path(data_dir: String) -> String {
  data_dir <> "/harness/prompts.jsonl"
}

pub fn marker_path(data_dir: String) -> String {
  data_dir <> "/" <> marker_file
}

/// Refuse the configuration when recording could expose real people.
pub fn validate(cfg: config.Config) -> Result(Nil, String) {
  case cfg.sim.record_prompts {
    False -> Ok(Nil)
    True ->
      case file_exists(marker_path(cfg.data_dir)) {
        Ok(True) -> validate_principals(cfg)
        _ ->
          Error(
            "sim.record_prompts requires a harness data_dir (missing .harness marker)",
          )
      }
  }
}

fn validate_principals(cfg: config.Config) -> Result(Nil, String) {
  let principals = list.append(cfg.access.admins, cfg.access.members)
  let foreign =
    principals
    |> list.filter(fn(principal) { !string.starts_with(principal, "sim:") })
  case foreign {
    [] -> Ok(Nil)
    [principal, ..] ->
      Error(
        "sim.record_prompts only accepts sim: principals, found " <> principal,
      )
  }
}

/// Append one line for one agent LLM call. Never fails the call.
pub fn record(
  principal: String,
  purpose: String,
  messages: List(provider.ChatMessage),
) -> Nil {
  case principal == "", enabled() {
    True, _ | _, False -> Nil
    False, True ->
      case closed_group_global.get_config() {
        None -> Nil
        Some(cfg) -> {
          let content =
            messages
            |> list.map(fn(message) { message.role <> ": " <> message.content })
            |> string.join("\n---\n")
          let line =
            json.to_string(
              json.object([
                #("type", json.string("prompt")),
                #("principal_id", json.string(principal)),
                #("purpose", json.string(purpose)),
                #("content", json.string(content)),
              ]),
            )
          let path = prompts_path(cfg.data_dir)
          let _ = case ensure_dir(cfg.data_dir <> "/harness") {
            Ok(_) -> append_file(path, line <> "\n")
            Error(_) -> Ok(Nil)
          }
          Nil
        }
      }
  }
}

fn enabled() -> Bool {
  case closed_group_global.get_config() {
    Some(cfg) -> cfg.sim.record_prompts
    None -> False
  }
}

pub fn read_all(data_dir: String) -> List(String) {
  case read_file(prompts_path(data_dir)) {
    Error(_) -> []
    Ok(raw) ->
      raw
      |> string.split("\n")
      |> list.filter(fn(line) { string.trim(line) != "" })
  }
}

pub fn decode_line(line: String) -> Option(PromptRecord) {
  let decoder = {
    use principal_id <- decode.field("principal_id", decode.string)
    use purpose <- decode.field("purpose", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(PromptRecord(
      principal_id: principal_id,
      purpose: purpose,
      content: content,
    ))
  }
  case json.parse(from: line, using: decoder) {
    Ok(record) -> Some(record)
    Error(_) -> None
  }
}

pub type PromptRecord {
  PromptRecord(principal_id: String, purpose: String, content: String)
}

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "append_file")
fn append_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)
