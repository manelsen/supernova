//// KernelAPI — Actor
////
//// OTP actor for kernel introspection API.
//// Provides tools for agents to query system state:
//// - kernel.status: query running agents and their states
//// - kernel.world_query: query facts from the world model
//// - kernel.audit_recent: query recent audit entries
//// - kernel.set_priority: modify agent scheduling priority
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(api) = actor.start(scheduler, world_model, audit_log)
//// let result = actor.handle(api, "agent_1", Status)
//// actor.stop(api)
//// ```

import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import supernova/core/audit_log/actor as audit_actor
import supernova/core/kernel_api/pure
import supernova/core/kernel_api/types.{
  type KernelApiOp, type KernelApiResult, AuditRecent, KernelApiError,
  KernelApiOk, SetPriority, Status, WorldQuery,
}
import supernova/core/kernel_scheduler/actor as scheduler_actor
import supernova/core/tool_registry
import supernova/core/world_model/actor as world_actor
import supernova/core/world_model/types as world_model_types
import supernova/llm/provider

// ============================================================================
// Types
// ============================================================================

/// Messages handled by the kernel API actor.
pub type KernelApiMessage {
  /// Handle a kernel API operation for an agent
  Handle(reply_to: Subject(KernelApiResult), agent_id: String, op: KernelApiOp)
  /// Get the tool definitions for all kernel API tools
  GetToolDefinitions(reply_to: Subject(List(provider.ToolDefinition)))
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running kernel API actor.
pub type KernelApiHandle =
  Subject(KernelApiMessage)

/// Internal actor state.
type ActorState {
  ActorState(
    scheduler: scheduler_actor.KernelSchedulerHandle,
    world_model: world_actor.WorldModelHandle,
    audit_log: audit_actor.AuditLog,
  )
}

// ============================================================================
// Tool Definitions
// ============================================================================

/// Get the tool definition for kernel.status.
pub fn kernel_status_tool() -> provider.ToolDefinition {
  provider.new_tool(
    "kernel.status",
    "Query the status of all registered agents in the kernel. Returns agent IDs, status (idle/running/starved/exhausted), priority, budget remaining, and last run time.",
    [],
  )
}

/// Get the tool definition for kernel.world_query.
pub fn kernel_world_query_tool() -> provider.ToolDefinition {
  provider.new_tool(
    "kernel.world_query",
    "Query facts from the world model by content pattern. Returns matching facts with their id, type, content, author, confidence, version, and creation timestamp.",
    [
      provider.string_param(
        "pattern",
        "Content pattern to search for in facts",
        False,
      ),
    ],
  )
}

/// Get the tool definition for kernel.audit_recent.
pub fn kernel_audit_recent_tool() -> provider.ToolDefinition {
  provider.new_tool(
    "kernel.audit_recent",
    "Query recent audit log entries for a specific agent. Returns timestamp, agent_id, operation, target, result, and details for each entry.",
    [
      provider.string_param(
        "agent_id",
        "The agent ID to query audit entries for",
        True,
      ),
      provider.integer_param(
        "limit",
        "Maximum number of entries to return (default: 10)",
        False,
      ),
    ],
  )
}

/// Get the tool definition for kernel.set_priority.
pub fn kernel_set_priority_tool() -> provider.ToolDefinition {
  provider.new_tool(
    "kernel.set_priority",
    "Set the scheduling priority of a registered agent. Valid priorities: critical, high, normal, low.",
    [
      provider.string_param(
        "agent_id",
        "The agent ID to set priority for",
        True,
      ),
      provider.string_param(
        "priority",
        "The new priority level (critical, high, normal, low)",
        True,
      ),
    ],
  )
}

/// Get all kernel API tool definitions.
pub fn all_tool_definitions() -> List(provider.ToolDefinition) {
  [
    kernel_status_tool(),
    kernel_world_query_tool(),
    kernel_audit_recent_tool(),
    kernel_set_priority_tool(),
  ]
}

// ============================================================================
// Operation Handlers
// ============================================================================

/// Handle a Status operation.
fn handle_status(state: ActorState) -> KernelApiResult {
  let infos = scheduler_actor.status(state.scheduler)
  pure.status_from_infos(infos)
}

/// Handle a WorldQuery operation.
fn handle_world_query(state: ActorState, pattern: String) -> KernelApiResult {
  let world_pattern =
    world_model_types.FactPattern(
      fact_type: None,
      author: None,
      content_contains: case string.is_empty(pattern) {
        True -> None
        False -> Some(pattern)
      },
    )
  let facts = world_actor.query(state.world_model, world_pattern)
  pure.world_query_result(facts)
}

/// Handle an AuditRecent operation.
fn handle_audit_recent(
  state: ActorState,
  agent_id: String,
  limit: Int,
) -> KernelApiResult {
  let entries = audit_actor.recent(state.audit_log, agent_id, limit)
  pure.audit_result(entries)
}

/// Handle a SetPriority operation.
fn handle_set_priority(
  state: ActorState,
  target_agent_id: String,
  priority_str: String,
) -> KernelApiResult {
  case pure.parse_priority(priority_str) {
    Error(e) -> pure.error_result(e)
    Ok(priority) -> {
      case
        scheduler_actor.set_priority(state.scheduler, target_agent_id, priority)
      {
        Ok(_) -> pure.set_priority_result(target_agent_id)
        Error(e) -> pure.error_result(e)
      }
    }
  }
}

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: ActorState,
  message: KernelApiMessage,
) -> actor.Next(ActorState, KernelApiMessage) {
  case message {
    Handle(reply_to, _agent_id, op) -> {
      let result = case op {
        Status -> handle_status(state)
        WorldQuery(pattern) -> handle_world_query(state, pattern)
        AuditRecent(target_agent_id, limit) ->
          handle_audit_recent(state, target_agent_id, limit)
        SetPriority(target_agent_id, priority) ->
          handle_set_priority(
            state,
            target_agent_id,
            pure.priority_to_string(priority),
          )
      }
      actor.send(reply_to, result)
      actor.continue(state)
    }

    GetToolDefinitions(reply_to) -> {
      actor.send(reply_to, all_tool_definitions())
      actor.continue(state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start the kernel API actor with handles to other system actors.
pub fn start(
  scheduler: scheduler_actor.KernelSchedulerHandle,
  world_model: world_actor.WorldModelHandle,
  audit_log: audit_actor.AuditLog,
) -> Result(KernelApiHandle, actor.StartError) {
  let initial_state =
    ActorState(
      scheduler: scheduler,
      world_model: world_model,
      audit_log: audit_log,
    )

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Handle a kernel API operation.
pub fn handle(
  api: KernelApiHandle,
  agent_id: String,
  op: KernelApiOp,
) -> KernelApiResult {
  actor.call(api, waiting: 5000, sending: Handle(_, agent_id, op))
}

/// Get all kernel API tool definitions.
pub fn get_tool_definitions(
  api: KernelApiHandle,
) -> List(provider.ToolDefinition) {
  actor.call(api, waiting: 5000, sending: GetToolDefinitions)
}

/// Stop the kernel API actor.
pub fn stop(api: KernelApiHandle) -> Nil {
  actor.call(api, waiting: 5000, sending: Stop)
}

// ============================================================================
// Auto-Registration to ToolRegistry
// ============================================================================

/// Result of registering kernel tools to a tool registry.
pub type KernelToolRegistrationResult {
  RegistrationSuccess
  RegistrationPartialFailure(failed: List(String))
  RegistrationFailure(message: String)
}

/// Arguments passed to a kernel tool handler.
type KernelToolArgs {
  WorldQueryArgs(pattern: String)
  AuditRecentArgs(agent_id: String, limit: Int)
  SetPriorityArgs(target_agent_id: String, priority: String)
}

/// Decoder for world_query arguments.
fn world_query_args_decoder() -> decode.Decoder(KernelToolArgs) {
  use pattern <- decode.field("pattern", decode.string)
  decode.success(WorldQueryArgs(pattern: pattern))
}

/// Parse JSON arguments for kernel.world_query.
fn parse_world_query_args(args: String) -> KernelToolArgs {
  case json.parse(from: args, using: world_query_args_decoder()) {
    Ok(args_result) -> args_result
    Error(_) -> WorldQueryArgs(pattern: "")
  }
}

/// Decoder for audit_recent arguments.
fn audit_recent_args_decoder() -> decode.Decoder(KernelToolArgs) {
  use agent_id <- decode.field("agent_id", decode.string)
  use limit <- decode.optional_field("limit", 10, decode.int)
  decode.success(AuditRecentArgs(agent_id: agent_id, limit: limit))
}

/// Parse JSON arguments for kernel.audit_recent.
fn parse_audit_recent_args(args: String) -> KernelToolArgs {
  case json.parse(from: args, using: audit_recent_args_decoder()) {
    Ok(args_result) -> args_result
    Error(_) -> AuditRecentArgs(agent_id: "", limit: 10)
  }
}

/// Decoder for set_priority arguments.
fn set_priority_args_decoder() -> decode.Decoder(KernelToolArgs) {
  use agent_id <- decode.field("agent_id", decode.string)
  use priority <- decode.field("priority", decode.string)
  decode.success(SetPriorityArgs(target_agent_id: agent_id, priority: priority))
}

/// Parse JSON arguments for kernel.set_priority.
fn parse_set_priority_args(args: String) -> KernelToolArgs {
  case json.parse(from: args, using: set_priority_args_decoder()) {
    Ok(args_result) -> args_result
    Error(_) -> SetPriorityArgs(target_agent_id: "", priority: "normal")
  }
}

/// Convert KernelApiResult to JSON string for tool response.
fn result_to_json_string(result: KernelApiResult) -> String {
  case result {
    KernelApiOk(data) -> "{\"ok\":true,\"data\":" <> data <> "}"
    KernelApiError(message) ->
      "{\"ok\":false,\"error\":\""
      <> string.replace(message, "\"", "\\\"")
      <> "\"}"
  }
}

/// Handler for kernel.status tool.
fn kernel_status_handler(
  api: KernelApiHandle,
  agent_id: String,
  _args: String,
) -> Result(String, String) {
  let result =
    actor.call(api, waiting: 5000, sending: Handle(_, agent_id, Status))
  Ok(result_to_json_string(result))
}

/// Handler for kernel.world_query tool.
fn kernel_world_query_handler(
  api: KernelApiHandle,
  agent_id: String,
  args: String,
) -> Result(String, String) {
  let parsed = parse_world_query_args(args)
  case parsed {
    WorldQueryArgs(pattern) -> {
      let result =
        actor.call(api, waiting: 5000, sending: Handle(
          _,
          agent_id,
          WorldQuery(pattern),
        ))
      Ok(result_to_json_string(result))
    }
    _ -> Error("Invalid arguments for kernel.world_query")
  }
}

/// Handler for kernel.audit_recent tool.
fn kernel_audit_recent_handler(
  api: KernelApiHandle,
  agent_id: String,
  args: String,
) -> Result(String, String) {
  let parsed = parse_audit_recent_args(args)
  case parsed {
    AuditRecentArgs(target_agent_id, limit) -> {
      let result =
        actor.call(api, waiting: 5000, sending: Handle(
          _,
          agent_id,
          AuditRecent(target_agent_id, limit),
        ))
      Ok(result_to_json_string(result))
    }
    _ -> Error("Invalid arguments for kernel.audit_recent")
  }
}

/// Handler for kernel.set_priority tool.
fn kernel_set_priority_handler(
  api: KernelApiHandle,
  agent_id: String,
  args: String,
) -> Result(String, String) {
  let parsed = parse_set_priority_args(args)
  case parsed {
    SetPriorityArgs(target_agent_id, priority) -> {
      case pure.parse_priority(priority) {
        Ok(p) -> {
          let result =
            actor.call(api, waiting: 5000, sending: Handle(
              _,
              agent_id,
              SetPriority(target_agent_id, p),
            ))
          Ok(result_to_json_string(result))
        }
        Error(e) -> Error(e)
      }
    }
    _ -> Error("Invalid arguments for kernel.set_priority")
  }
}

/// Register all kernel API tools to a ToolRegistry automatically.
///
/// This function registers the four kernel tools (kernel.status,
/// kernel.world_query, kernel.audit_recent, kernel.set_priority) to the
/// provided ToolRegistry with handlers that dispatch to this kernel API actor.
///
/// Returns RegistrationSuccess if all tools registered successfully,
/// RegistrationPartialFailure if some failed, or RegistrationFailure if
/// all failed.
pub fn register_to_tool_registry(
  api: KernelApiHandle,
  registry: tool_registry.ToolRegistry,
) -> KernelToolRegistrationResult {
  // Create handlers that capture api and a default agent_id
  // The tool_registry passes args as the only parameter to the handler
  let status_handler = fn(args: String) -> Result(String, String) {
    kernel_status_handler(api, "system", args)
  }
  let world_query_handler = fn(args: String) -> Result(String, String) {
    kernel_world_query_handler(api, "system", args)
  }
  let audit_recent_handler = fn(args: String) -> Result(String, String) {
    kernel_audit_recent_handler(api, "system", args)
  }
  let set_priority_handler = fn(args: String) -> Result(String, String) {
    kernel_set_priority_handler(api, "system", args)
  }

  let tools_with_handlers = [
    #(kernel_status_tool(), status_handler),
    #(kernel_world_query_tool(), world_query_handler),
    #(kernel_audit_recent_tool(), audit_recent_handler),
    #(kernel_set_priority_tool(), set_priority_handler),
  ]

  let failed =
    list.filter_map(tools_with_handlers, fn(entry) {
      let #(tool, handler) = entry
      case tool_registry.register(registry, tool, handler) {
        Ok(_) -> Error(Nil)
        Error(e) -> Ok(tool.name <> ": " <> e)
      }
    })

  case failed {
    [] -> RegistrationSuccess
    [_] -> RegistrationPartialFailure(failed: failed)
    _ -> RegistrationPartialFailure(failed: failed)
  }
}
