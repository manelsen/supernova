//// Process Tool — list, inspect, and terminate OS processes.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/core/workspace_policy/actor as policy_actor
import supernova/core/workspace_policy/types.{OpShell}
import supernova/llm/provider

pub type ProcessSnapshot {
  ProcessSnapshot(pid: Int, cpu: String, memory: String, command: String)
}

type ProcessArgs {
  ProcessArgs(action: String, pid: Option(Int))
}

pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "process",
    description: "List running processes, inspect a PID, or terminate a PID",
    parameters: [
      provider.string_param("action", "Action: list, info, kill", True),
      provider.integer_param("pid", "Target process id for info or kill", False),
    ],
  )
}

pub fn execute(args_json: String) -> Result(String, String) {
  case json.parse(from: args_json, using: process_args_decoder()) {
    Error(error) ->
      Error("Invalid arguments for process: " <> string.inspect(error))
    Ok(args) -> execute_args(args)
  }
}

pub fn list() -> Result(String, String) {
  case do_list_processes() {
    Ok(lines) ->
      case parse_snapshots(lines) {
        Ok(snapshots) -> Ok(render_listing(snapshots))
        Error(reason) -> Error(reason)
      }
    Error(reason) -> Error(reason)
  }
}

pub fn info(pid: Int) -> Result(String, String) {
  use valid_pid <- result.try(validate_pid(pid))

  case do_process_info(valid_pid) {
    Ok(line) ->
      case parse_snapshot(line) {
        Ok(snapshot) -> Ok(render_snapshot(snapshot))
        Error(reason) -> Error(reason)
      }
    Error(reason) -> Error(reason)
  }
}

pub fn kill(pid: Int) -> Result(String, String) {
  use valid_pid <- result.try(validate_pid(pid))

  case do_kill_process(valid_pid) {
    Ok(_) -> Ok("killed " <> int.to_string(valid_pid))
    Error(reason) -> Error(reason)
  }
}

pub fn list_authorized(
  policy: policy_actor.WorkspacePolicy,
  agent_id: String,
) -> Result(String, String) {
  case do_list_processes() {
    Ok(lines) ->
      case parse_snapshots(lines) {
        Ok(snapshots) ->
          snapshots
          |> filter_authorized_snapshots(policy, agent_id, [])
          |> render_listing
          |> Ok
        Error(reason) -> Error(reason)
      }
    Error(reason) -> Error(reason)
  }
}

pub fn info_authorized(
  policy: policy_actor.WorkspacePolicy,
  agent_id: String,
  pid: Int,
) -> Result(String, String) {
  use valid_pid <- result.try(validate_pid(pid))
  use snapshot <- result.try(lookup_snapshot(valid_pid))
  use _ <- result.try(authorize_snapshot(policy, agent_id, snapshot))
  Ok(render_snapshot(snapshot))
}

pub fn kill_authorized(
  policy: policy_actor.WorkspacePolicy,
  agent_id: String,
  pid: Int,
) -> Result(String, String) {
  use valid_pid <- result.try(validate_pid(pid))
  use snapshot <- result.try(lookup_snapshot(valid_pid))
  use _ <- result.try(authorize_snapshot(policy, agent_id, snapshot))
  kill(valid_pid)
}

fn execute_args(args: ProcessArgs) -> Result(String, String) {
  case string.lowercase(string.trim(args.action)) {
    "list" -> list()
    "info" ->
      case args.pid {
        Some(pid) -> info(pid)
        None -> Error("Invalid arguments for process: missing pid")
      }
    "kill" ->
      case args.pid {
        Some(pid) -> kill(pid)
        None -> Error("Invalid arguments for process: missing pid")
      }
    other ->
      Error(
        "Invalid arguments for process: action must be list, info, or kill (got "
        <> other
        <> ")",
      )
  }
}

fn process_args_decoder() -> decode.Decoder(ProcessArgs) {
  use action <- decode.field("action", decode.string)
  use pid <- decode.optional_field("pid", None, decode.int |> decode.map(Some))
  decode.success(ProcessArgs(action: action, pid: pid))
}

fn validate_pid(pid: Int) -> Result(Int, String) {
  case pid > 0 {
    True -> Ok(pid)
    False -> Error("Invalid process pid: " <> int.to_string(pid))
  }
}

fn lookup_snapshot(pid: Int) -> Result(ProcessSnapshot, String) {
  case do_process_info(pid) {
    Ok(line) -> parse_snapshot(line)
    Error(reason) -> Error(reason)
  }
}

fn authorize_snapshot(
  policy: policy_actor.WorkspacePolicy,
  agent_id: String,
  snapshot: ProcessSnapshot,
) -> Result(Nil, String) {
  let path = policy_path_for_command(snapshot.command)
  case policy_actor.authorize(policy, agent_id, OpShell, path) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

fn filter_authorized_snapshots(
  snapshots: List(ProcessSnapshot),
  policy: policy_actor.WorkspacePolicy,
  agent_id: String,
  acc: List(ProcessSnapshot),
) -> List(ProcessSnapshot) {
  case snapshots {
    [] -> list.reverse(acc)
    [snapshot, ..rest] ->
      case authorize_snapshot(policy, agent_id, snapshot) {
        Ok(_) ->
          filter_authorized_snapshots(rest, policy, agent_id, [snapshot, ..acc])
        Error(_) -> filter_authorized_snapshots(rest, policy, agent_id, acc)
      }
  }
}

fn policy_path_for_command(command: String) -> String {
  case command_tokens(command) {
    [shell, script, ..] ->
      case is_shell_interpreter(shell) && looks_like_path(script) {
        True -> normalize_policy_path(script)
        False -> normalize_policy_path(shell)
      }
    [first, ..] -> normalize_policy_path(first)
    [] -> "/external/unknown"
  }
}

fn command_tokens(command: String) -> List(String) {
  command
  |> string.trim
  |> string.split(" ")
  |> list.filter(fn(token) { string.trim(token) != "" })
}

fn is_shell_interpreter(token: String) -> Bool {
  token == "sh" || token == "/bin/sh" || token == "bash" || token == "/bin/bash"
}

fn looks_like_path(token: String) -> Bool {
  string.starts_with(token, "/")
  || string.contains(token, "/")
  || string.starts_with(token, ".")
}

fn normalize_policy_path(token: String) -> String {
  case looks_like_path(token) {
    True -> token
    False -> "/external/" <> token
  }
}

fn parse_snapshots(
  lines: List(String),
) -> Result(List(ProcessSnapshot), String) {
  parse_snapshots_acc(lines, [])
}

fn parse_snapshots_acc(
  lines: List(String),
  acc: List(ProcessSnapshot),
) -> Result(List(ProcessSnapshot), String) {
  case lines {
    [] -> Ok(list.reverse(acc))
    [line, ..rest] ->
      case parse_snapshot(line) {
        Ok(snapshot) -> parse_snapshots_acc(rest, [snapshot, ..acc])
        Error(reason) -> Error(reason)
      }
  }
}

fn parse_snapshot(line: String) -> Result(ProcessSnapshot, String) {
  case string.split(line, "\t") {
    [pid_text, cpu, memory, command] ->
      case int.parse(pid_text) {
        Ok(pid) ->
          Ok(ProcessSnapshot(
            pid: pid,
            cpu: cpu,
            memory: memory,
            command: command,
          ))
        Error(_) -> Error("Invalid process listing pid: " <> pid_text)
      }
    _ -> Error("Invalid process listing line: " <> line)
  }
}

fn render_listing(snapshots: List(ProcessSnapshot)) -> String {
  snapshots
  |> list.map(fn(snapshot) {
    int.to_string(snapshot.pid)
    <> "\t"
    <> snapshot.cpu
    <> "\t"
    <> snapshot.memory
    <> "\t"
    <> snapshot.command
  })
  |> string.join("\n")
}

fn render_snapshot(snapshot: ProcessSnapshot) -> String {
  "pid="
  <> int.to_string(snapshot.pid)
  <> " cpu="
  <> snapshot.cpu
  <> " memory="
  <> snapshot.memory
  <> " command="
  <> snapshot.command
}

@external(erlang, "supernova_process_ffi", "list_processes")
fn do_list_processes() -> Result(List(String), String)

@external(erlang, "supernova_process_ffi", "process_info")
fn do_process_info(pid: Int) -> Result(String, String)

@external(erlang, "supernova_process_ffi", "kill_process")
fn do_kill_process(pid: Int) -> Result(String, String)
