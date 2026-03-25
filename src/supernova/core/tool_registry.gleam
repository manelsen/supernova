//// Tool Registry — actor-based registry for agent tools.
////
//// Manages tool definitions and their handlers. Tools can be registered,
//// listed, and executed by name. Used by the executor to dispatch tool calls.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(reg) = tool_registry.start()
//// let tool = provider.new_tool(name: "echo", ...)
//// tool_registry.register(reg, tool, fn(args) { Ok(args) })
//// tool_registry.execute(reg, "echo", "hello")
//// ```

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/string
import supernova/core/audit_log/actor as audit_actor
import supernova/core/audit_log/types as audit_types
import supernova/core/capability_manifest/pure as cap_pure
import supernova/core/capability_manifest/types.{type CapabilityManifest}
import supernova/llm/provider

// ============================================================================
// FFI — Timestamp (Erlang)
// ============================================================================

/// Get current timestamp in milliseconds (Erlang FFI).
@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

// ============================================================================
// Types
// ============================================================================

/// A registered tool with its handler function.
type RegisteredTool {
  RegisteredTool(
    spec: provider.ToolDefinition,
    handler: fn(String) -> Result(String, String),
  )
}

/// Messages for the registry actor.
pub type RegistryMessage {
  RegisterTool(
    reply_to: Subject(Result(Nil, String)),
    spec: provider.ToolDefinition,
    handler: fn(String) -> Result(String, String),
  )
  ListTools(reply_to: Subject(List(String)))
  ListToolsForAgent(reply_to: Subject(List(String)), agent_id: String)
  GetToolSpec(
    reply_to: Subject(Result(provider.ToolDefinition, String)),
    name: String,
  )
  ExecuteTool(
    reply_to: Subject(Result(String, String)),
    name: String,
    args: String,
  )
  ExecuteToolForAgent(
    reply_to: Subject(Result(String, String)),
    agent_id: String,
    name: String,
    args: String,
  )
  SetCapabilityManifest(reply_to: Subject(Nil), manifest: CapabilityManifest)
  GetCapabilityManifest(reply_to: Subject(Option(CapabilityManifest)))
}

/// Registry state.
type RegistryState {
  RegistryState(
    tools: Dict(String, RegisteredTool),
    capability_manifest: Option(CapabilityManifest),
    audit_log: Option(audit_actor.AuditLog),
  )
}

/// The registry handle.
pub type ToolRegistry =
  Subject(RegistryMessage)

// ============================================================================
// Audit Helper
// ============================================================================

/// Log a tool execution audit entry if audit log is available.
fn log_tool_audit(
  audit_log: Option(audit_actor.AuditLog),
  agent_id: String,
  tool_name: String,
  result: Result(String, String),
) -> Nil {
  case audit_log {
    Some(log) -> {
      let timestamp = ffi_current_timestamp()
      let entry = case result {
        Ok(_) ->
          audit_types.success_entry(
            timestamp,
            agent_id,
            "tool_call",
            tool_name,
            "Tool executed successfully",
          )
        Error(reason) ->
          audit_types.failure_entry(
            timestamp,
            agent_id,
            "tool_call",
            tool_name,
            reason,
          )
      }
      audit_actor.log_entry(log, entry)
    }
    None -> Nil
  }
}

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: RegistryState,
  message: RegistryMessage,
) -> actor.Next(RegistryState, RegistryMessage) {
  case message {
    RegisterTool(reply_to, spec, handler) -> {
      case dict.get(state.tools, spec.name) {
        Ok(_) -> {
          actor.send(reply_to, Error("Tool already registered: " <> spec.name))
          actor.continue(state)
        }
        Error(_) -> {
          let registered = RegisteredTool(spec: spec, handler: handler)
          let new_tools = dict.insert(state.tools, spec.name, registered)
          actor.send(reply_to, Ok(Nil))
          actor.continue(RegistryState(..state, tools: new_tools))
        }
      }
    }

    ListTools(reply_to) -> {
      let names =
        state.tools
        |> dict.keys
        |> list.sort(string_compare)
      actor.send(reply_to, names)
      actor.continue(state)
    }

    ListToolsForAgent(reply_to, _agent_id) -> {
      let all_tools =
        state.tools
        |> dict.keys
        |> list.sort(string_compare)
      let filtered = case state.capability_manifest {
        Some(manifest) ->
          list.filter(all_tools, fn(name) { cap_pure.allowed(manifest, name) })
        None -> all_tools
      }
      actor.send(reply_to, filtered)
      actor.continue(state)
    }

    GetToolSpec(reply_to, name) -> {
      case dict.get(state.tools, name) {
        Ok(registered) -> {
          actor.send(reply_to, Ok(registered.spec))
          actor.continue(state)
        }
        Error(_) -> {
          actor.send(reply_to, Error("Tool not found: " <> name))
          actor.continue(state)
        }
      }
    }

    ExecuteTool(reply_to, name, args) -> {
      case dict.get(state.tools, name) {
        Ok(registered) -> {
          let result = registered.handler(args)
          // Audit the tool execution
          log_tool_audit(state.audit_log, "system", name, result)
          actor.send(reply_to, result)
          actor.continue(state)
        }
        Error(_) -> {
          // Audit tool not found
          log_tool_audit(
            state.audit_log,
            "system",
            name,
            Error("Tool not found: " <> name),
          )
          actor.send(reply_to, Error("Tool not found: " <> name))
          actor.continue(state)
        }
      }
    }

    ExecuteToolForAgent(reply_to, agent_id, name, args) -> {
      // Check capability first
      let capability_ok = case state.capability_manifest {
        Some(manifest) -> cap_pure.allowed(manifest, name)
        None -> True
      }
      case capability_ok {
        False -> {
          // Audit capability denied
          log_tool_audit(
            state.audit_log,
            agent_id,
            name,
            Error("capability_denied"),
          )
          actor.send(
            reply_to,
            Error(
              "capability_denied: tool '"
              <> name
              <> "' not allowed for agent "
              <> agent_id,
            ),
          )
          actor.continue(state)
        }
        True -> {
          case dict.get(state.tools, name) {
            Ok(registered) -> {
              let result = registered.handler(args)
              // Audit the tool execution
              log_tool_audit(state.audit_log, agent_id, name, result)
              actor.send(reply_to, result)
              actor.continue(state)
            }
            Error(_) -> {
              // Audit tool not found
              log_tool_audit(
                state.audit_log,
                agent_id,
                name,
                Error("Tool not found: " <> name),
              )
              actor.send(reply_to, Error("Tool not found: " <> name))
              actor.continue(state)
            }
          }
        }
      }
    }

    SetCapabilityManifest(reply_to, manifest) -> {
      actor.send(reply_to, Nil)
      actor.continue(
        RegistryState(..state, capability_manifest: Some(manifest)),
      )
    }

    GetCapabilityManifest(reply_to) -> {
      actor.send(reply_to, state.capability_manifest)
      actor.continue(state)
    }
  }
}

fn string_compare(a: String, b: String) -> order.Order {
  string.compare(a, b)
}

// ============================================================================
// Public API
// ============================================================================

/// Start a new tool registry.
pub fn start() -> Result(ToolRegistry, actor.StartError) {
  let initial_state =
    RegistryState(tools: dict.new(), capability_manifest: None, audit_log: None)

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(reason) -> Error(reason)
  }
}

/// Start a new tool registry with an audit log reference.
pub fn start_with_audit(
  audit_log: audit_actor.AuditLog,
) -> Result(ToolRegistry, actor.StartError) {
  let initial_state =
    RegistryState(
      tools: dict.new(),
      capability_manifest: None,
      audit_log: Some(audit_log),
    )

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(reason) -> Error(reason)
  }
}

/// Register a tool with its handler.
pub fn register(
  registry: ToolRegistry,
  spec: provider.ToolDefinition,
  handler: fn(String) -> Result(String, String),
) -> Result(Nil, String) {
  actor.call(registry, waiting: 5000, sending: RegisterTool(_, spec, handler))
}

/// List all registered tool names.
pub fn list_tools(registry: ToolRegistry) -> List(String) {
  actor.call(registry, waiting: 5000, sending: ListTools)
}

/// Get a tool's definition by name.
pub fn get_tool(
  registry: ToolRegistry,
  name: String,
) -> Result(provider.ToolDefinition, String) {
  actor.call(registry, waiting: 5000, sending: GetToolSpec(_, name))
}

/// Execute a tool by name with JSON arguments.
pub fn execute(
  registry: ToolRegistry,
  name: String,
  args: String,
) -> Result(String, String) {
  actor.call(registry, waiting: 5000, sending: ExecuteTool(_, name, args))
}

/// List tools available to a specific agent (filtered by capability manifest).
pub fn list_tools_for_agent(
  registry: ToolRegistry,
  agent_id: String,
) -> List(String) {
  actor.call(registry, waiting: 5000, sending: ListToolsForAgent(_, agent_id))
}

/// Execute a tool for a specific agent with capability checking.
/// Returns Error("capability_denied: ...") if the tool is not allowed.
pub fn execute_for_agent(
  registry: ToolRegistry,
  agent_id: String,
  name: String,
  args: String,
) -> Result(String, String) {
  actor.call(registry, waiting: 5000, sending: ExecuteToolForAgent(
    _,
    agent_id,
    name,
    args,
  ))
}

/// Set the capability manifest for the registry.
pub fn set_capability_manifest(
  registry: ToolRegistry,
  manifest: CapabilityManifest,
) -> Nil {
  actor.call(registry, waiting: 5000, sending: SetCapabilityManifest(
    _,
    manifest,
  ))
}

/// Get the current capability manifest.
pub fn get_capability_manifest(
  registry: ToolRegistry,
) -> Option(CapabilityManifest) {
  actor.call(registry, waiting: 5000, sending: GetCapabilityManifest)
}
