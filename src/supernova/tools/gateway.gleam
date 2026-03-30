//// Gateway Tool — one-shot facade over the kernel syscall gateway.
////
//// Scope definition for `US-014`:
//// - This tool is not a long-lived runtime gateway manager.
//// - It is a one-shot facade that exercises the real `SyscallGateway`
////   pipeline in-process per call.
//// - Each invocation may start a gateway actor, optionally register the
////   calling agent, invoke one formal `SyscallOp`, and return the rendered
////   result.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/core/syscall/actor as syscall_actor
import supernova/core/syscall/types.{
  type SyscallOp, type SyscallResult, CancelSchedule, EmitEvent, GetBudget,
  KillAgent, ReadFile, ReadWorld, Schedule, SpawnAgent, SyscallDenied,
  SyscallFailed, SyscallOk, WriteFile, WriteWorld,
}
import supernova/llm/provider

const default_agent_id = "gateway_tool"

type GatewayArgs {
  GatewayArgs(
    action: String,
    agent_id: Option(String),
    register_agent: Bool,
    config: Option(String),
    target_id: Option(String),
    content_pattern: Option(String),
    content: Option(String),
    confidence: Option(Float),
    path: Option(String),
    task_id: Option(String),
    delay_ms: Option(Int),
    event_type: Option(String),
    payload: Option(String),
  )
}

pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "gateway",
    description: "Exercise the Supernova syscall gateway as a one-shot facade for formal kernel operations",
    parameters: [
      provider.string_param(
        "action",
        "Gateway action: describe, spawn_agent, kill_agent, read_world, write_world, read_file, write_file, schedule, cancel_schedule, get_budget, emit_event",
        True,
      ),
      provider.string_param(
        "agent_id",
        "Optional synthetic agent id for the one-shot gateway call",
        False,
      ),
      provider.boolean_param(
        "register_agent",
        "Whether to register the synthetic agent before invoking the syscall",
        False,
      ),
      provider.string_param("config", "SpawnAgent config JSON", False),
      provider.string_param("target_id", "KillAgent target id", False),
      provider.string_param(
        "content_pattern",
        "ReadWorld search pattern",
        False,
      ),
      provider.string_param("content", "WriteWorld or WriteFile content", False),
      provider.string_param("path", "ReadFile or WriteFile path", False),
      provider.string_param(
        "task_id",
        "Schedule or CancelSchedule task id",
        False,
      ),
      provider.integer_param(
        "delay_ms",
        "Schedule delay in milliseconds",
        False,
      ),
      provider.string_param("event_type", "EmitEvent type", False),
      provider.string_param("payload", "EmitEvent payload", False),
    ],
  )
}

pub fn describe_scope() -> String {
  [
    "gateway tool scope: one-shot facade over the in-process SyscallGateway",
    "actions: describe, spawn_agent, kill_agent, read_world, write_world, read_file, write_file, schedule, cancel_schedule, get_budget, emit_event",
    "state model: no persistent gateway session is kept between tool calls",
    "result model: gateway denials/failures are returned as rendered results, while malformed tool arguments remain execution errors",
  ]
  |> string.join("\n")
}

pub fn execute(args_json: String) -> Result(String, String) {
  case json.parse(from: args_json, using: gateway_args_decoder()) {
    Ok(args) -> dispatch(args)
    Error(error) ->
      Error("Invalid arguments for gateway: " <> string.inspect(error))
  }
}

fn dispatch(args: GatewayArgs) -> Result(String, String) {
  let action = normalize_action(args.action)

  case action {
    "describe" -> Ok(describe_scope())
    _ -> {
      let agent_id = normalize_agent_id(args.agent_id)
      use op <- result.try(build_syscall_op(args, action))
      invoke_once(agent_id, args.register_agent, op)
    }
  }
}

fn gateway_args_decoder() -> decode.Decoder(GatewayArgs) {
  use action <- decode.field("action", decode.string)
  use agent_id <- decode.optional_field(
    "agent_id",
    None,
    decode.optional(decode.string),
  )
  use register_agent <- decode.optional_field(
    "register_agent",
    True,
    decode.bool,
  )
  use config <- decode.optional_field(
    "config",
    None,
    decode.optional(decode.string),
  )
  use target_id <- decode.optional_field(
    "target_id",
    None,
    decode.optional(decode.string),
  )
  use content_pattern <- decode.optional_field(
    "content_pattern",
    None,
    decode.optional(decode.string),
  )
  use content <- decode.optional_field(
    "content",
    None,
    decode.optional(decode.string),
  )
  use confidence <- decode.optional_field(
    "confidence",
    None,
    decode.optional(decode.float),
  )
  use path <- decode.optional_field(
    "path",
    None,
    decode.optional(decode.string),
  )
  use task_id <- decode.optional_field(
    "task_id",
    None,
    decode.optional(decode.string),
  )
  use delay_ms <- decode.optional_field(
    "delay_ms",
    None,
    decode.optional(decode.int),
  )
  use event_type <- decode.optional_field(
    "event_type",
    None,
    decode.optional(decode.string),
  )
  use payload <- decode.optional_field(
    "payload",
    None,
    decode.optional(decode.string),
  )

  decode.success(GatewayArgs(
    action: action,
    agent_id: agent_id,
    register_agent: register_agent,
    config: config,
    target_id: target_id,
    content_pattern: content_pattern,
    content: content,
    confidence: confidence,
    path: path,
    task_id: task_id,
    delay_ms: delay_ms,
    event_type: event_type,
    payload: payload,
  ))
}

fn build_syscall_op(
  args: GatewayArgs,
  action: String,
) -> Result(SyscallOp, String) {
  case action {
    "spawn_agent" ->
      require_text(args.config, "config", action)
      |> result.map(SpawnAgent)
    "kill_agent" ->
      require_text(args.target_id, "target_id", action)
      |> result.map(KillAgent)
    "read_world" ->
      require_text(args.content_pattern, "content_pattern", action)
      |> result.map(ReadWorld)
    "write_world" -> {
      use content <- result.try(require_text(args.content, "content", action))
      Ok(WriteWorld(content, confidence_value(args.confidence)))
    }
    "read_file" ->
      require_text(args.path, "path", action)
      |> result.map(ReadFile)
    "write_file" -> {
      use path <- result.try(require_text(args.path, "path", action))
      use content <- result.try(require_text(args.content, "content", action))
      Ok(WriteFile(path, content))
    }
    "schedule" -> {
      use task_id <- result.try(require_text(args.task_id, "task_id", action))
      use delay_ms <- result.try(require_int(args.delay_ms, "delay_ms", action))
      Ok(Schedule(task_id, delay_ms))
    }
    "cancel_schedule" ->
      require_text(args.task_id, "task_id", action)
      |> result.map(CancelSchedule)
    "get_budget" -> Ok(GetBudget)
    "emit_event" -> {
      use event_type <- result.try(require_text(
        args.event_type,
        "event_type",
        action,
      ))
      use payload <- result.try(require_text(args.payload, "payload", action))
      Ok(EmitEvent(event_type, payload))
    }
    _ -> Error("Invalid arguments for gateway: unknown action " <> action)
  }
}

fn invoke_once(
  agent_id: String,
  register_agent: Bool,
  op: SyscallOp,
) -> Result(String, String) {
  case syscall_actor.start() {
    Error(error) ->
      Error(
        "Invalid arguments for gateway: could not start syscall gateway: "
        <> string.inspect(error),
      )
    Ok(gateway) -> {
      case register_agent {
        True -> syscall_actor.register_agent(gateway, agent_id)
        False -> Nil
      }

      let result = syscall_actor.invoke(gateway, agent_id, op)
      syscall_actor.stop(gateway)
      Ok(render_result(result))
    }
  }
}

fn render_result(result: SyscallResult) -> String {
  case result {
    SyscallOk(data) -> "ok: " <> data
    SyscallDenied(reason) -> "denied: " <> reason
    SyscallFailed(message) -> "failed: " <> message
  }
}

fn normalize_action(action: String) -> String {
  action |> string.trim |> string.lowercase
}

fn normalize_agent_id(agent_id: Option(String)) -> String {
  case agent_id {
    Some(value) -> {
      let normalized = string.trim(value)
      case normalized == "" {
        True -> default_agent_id
        False -> normalized
      }
    }
    None -> default_agent_id
  }
}

fn confidence_value(confidence: Option(Float)) -> Float {
  case confidence {
    Some(value) -> value
    None -> 1.0
  }
}

fn require_text(
  value: Option(String),
  field_name: String,
  action: String,
) -> Result(String, String) {
  case value {
    Some(text) -> {
      let normalized = string.trim(text)
      case normalized == "" {
        True ->
          Error(
            "Invalid arguments for gateway: missing "
            <> field_name
            <> " for "
            <> action,
          )
        False -> Ok(normalized)
      }
    }
    None ->
      Error(
        "Invalid arguments for gateway: missing "
        <> field_name
        <> " for "
        <> action,
      )
  }
}

fn require_int(
  value: Option(Int),
  field_name: String,
  action: String,
) -> Result(Int, String) {
  case value {
    Some(value) -> Ok(value)
    None ->
      Error(
        "Invalid arguments for gateway: missing "
        <> field_name
        <> " for "
        <> action,
      )
  }
}
