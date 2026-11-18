//// Syscall — Actor
////
//// Formal gateway for all agent→kernel interactions.
//// Enforces: authentication → WorkspacePolicy → BudgetPolicy → execution → AuditLog.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(gw) = actor.start()
//// actor.register_agent(gw, "agent_1")
//// let result = actor.invoke(gw, "agent_1", ReadFile("src/main.gleam"))
//// actor.stop(gw)
//// ```

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import supernova/core/audit_log/actor as audit_actor
import supernova/core/audit_log/types as audit_types
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/budget_policy/types as budget_types
import supernova/core/capability_manifest/pure as cap_pure
import supernova/core/capability_manifest/types as cap_types
import supernova/core/safe_call
import supernova/core/syscall/pure
import supernova/core/syscall/types.{
  type SyscallCommand, type SyscallOp, type SyscallResult, type SyscallState,
  AuditDenied, AuditFailed, AuditOk, CancelSchedule, EmitEvent, GetBudget,
  KillAgent, ReadFile, ReadWorld, RecordAudit, Schedule, SpawnAgent,
  SyscallDenied, SyscallFailed, SyscallOk, WriteFile, WriteWorld,
}
import supernova/core/workspace_policy/actor as policy_actor
import supernova/core/workspace_policy/types as policy_types

// ============================================================================
// FFI — Timestamp (Erlang)
// ============================================================================

/// Get current timestamp in milliseconds.
@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

// ============================================================================
// Types
// ============================================================================

/// Messages handled by the syscall gateway actor.
pub type SyscallMessage {
  /// Invoke a syscall on behalf of agent_id
  Invoke(reply_to: Subject(SyscallResult), agent_id: String, op: SyscallOp)
  /// Invoke a concrete tool on behalf of a principal through the kernel.
  InvokeTool(
    reply_to: Subject(Result(String, String)),
    principal_id: String,
    role: String,
    tool_name: String,
    args: String,
  )
  /// Register an agent to make syscalls
  RegisterAgent(reply_to: Subject(Nil), agent_id: String)
  /// Unregister an agent
  UnregisterAgent(reply_to: Subject(Nil), agent_id: String)
  /// Check if an agent is registered
  IsRegistered(reply_to: Subject(Bool), agent_id: String)
  /// Get the syscall invocation count for an agent
  GetCount(reply_to: Subject(Int), agent_id: String)
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running syscall gateway actor.
pub type SyscallGateway =
  Subject(SyscallMessage)

/// Internal actor state: pure syscall state + optional policy/audit handles.
type ActorState {
  ActorState(
    state: SyscallState,
    workspace_policy: Option(policy_actor.WorkspacePolicy),
    budget_policy: Option(budget_actor.BudgetPolicy),
    audit_log: Option(audit_actor.AuditLog),
    capability_manifests: Dict(String, cap_types.CapabilityManifest),
    tool_executor: fn(String, String) -> Result(String, String),
  )
}

// ============================================================================
// Command Execution
// ============================================================================

/// Execute audit commands returned by pure functions.
fn execute_commands(
  commands: List(SyscallCommand),
  audit_log: Option(audit_actor.AuditLog),
) -> Nil {
  list.each(commands, fn(cmd) {
    case cmd {
      RecordAudit(agent_id, operation, target, result_type, details, timestamp) -> {
        let audit_result = case result_type {
          AuditOk -> audit_types.AuditSuccess
          AuditDenied -> audit_types.AuditDenied
          AuditFailed -> audit_types.AuditFailure
        }
        let entry =
          audit_types.AuditEntry(
            timestamp: timestamp,
            agent_id: agent_id,
            operation: operation,
            target: target,
            result: audit_result,
            details: details,
          )
        case audit_log {
          Some(log) -> audit_actor.log_entry(log, entry)
          None -> Nil
        }
      }
    }
  })
}

// ============================================================================
// Pipeline Helpers
// ============================================================================

/// Check workspace policy for file operations.
/// Returns Ok(full_path) or Error(reason).
fn check_workspace_policy(
  actor_state: ActorState,
  agent_id: String,
  op: SyscallOp,
) -> Result(String, String) {
  case op {
    ReadFile(path) -> {
      case actor_state.workspace_policy {
        Some(policy) ->
          policy_actor.authorize(policy, agent_id, policy_types.OpRead, path)
        None -> Ok(path)
      }
    }
    WriteFile(path, _) -> {
      case actor_state.workspace_policy {
        Some(policy) ->
          policy_actor.authorize(policy, agent_id, policy_types.OpWrite, path)
        None -> Ok(path)
      }
    }
    // Non-file operations: no workspace check needed
    _ -> Ok("")
  }
}

/// Check budget policy for tool call consumption.
/// Returns Ok(Nil) or Error(reason).
fn check_budget_policy(
  actor_state: ActorState,
  agent_id: String,
) -> Result(Nil, String) {
  case actor_state.budget_policy {
    Some(policy) -> {
      case
        budget_actor.check(policy, agent_id, budget_types.BudgetToolCalls, 1)
      {
        Ok(_) -> Ok(Nil)
        Error(exceeded) -> Error(exceeded.message)
      }
    }
    None -> Ok(Nil)
  }
}

/// Write a syscall audit entry to the audit log.
fn audit_syscall(
  audit_log: Option(audit_actor.AuditLog),
  agent_id: String,
  operation: String,
  target: String,
  result: audit_types.AuditResult,
  details: String,
  timestamp: Int,
) -> Nil {
  case audit_log {
    Some(log) -> {
      let entry =
        audit_types.AuditEntry(
          timestamp: timestamp,
          agent_id: agent_id,
          operation: operation,
          target: target,
          result: result,
          details: details,
        )
      audit_actor.log_entry(log, entry)
    }
    None -> Nil
  }
}

/// Execute the actual syscall operation (steps 2-4 of the pipeline).
/// Runs: WorkspacePolicy → BudgetPolicy → execution.
/// Returns SyscallResult.
fn execute_op(
  actor_state: ActorState,
  agent_id: String,
  op: SyscallOp,
  timestamp: Int,
) -> SyscallResult {
  let op_name = types.op_to_string(op)
  let op_tgt = types.op_target(op)

  // Step 2: WorkspacePolicy check (for file operations)
  case check_workspace_policy(actor_state, agent_id, op) {
    Error(reason) -> {
      audit_syscall(
        actor_state.audit_log,
        agent_id,
        op_name,
        op_tgt,
        audit_types.AuditDenied,
        "workspace_policy: " <> reason,
        timestamp,
      )
      SyscallDenied(reason)
    }
    Ok(_) -> {
      // Step 3: BudgetPolicy check
      case check_budget_policy(actor_state, agent_id) {
        Error(reason) -> {
          audit_syscall(
            actor_state.audit_log,
            agent_id,
            op_name,
            op_tgt,
            audit_types.AuditDenied,
            "budget_policy: " <> reason,
            timestamp,
          )
          SyscallDenied(reason)
        }
        Ok(_) -> {
          // Step 4: Execute the operation
          let result = run_op(op, agent_id)

          // Step 5: AuditLog
          let #(audit_res, details) = case result {
            SyscallOk(data) -> #(audit_types.AuditSuccess, data)
            SyscallDenied(r) -> #(audit_types.AuditDenied, r)
            SyscallFailed(m) -> #(audit_types.AuditFailure, m)
          }
          audit_syscall(
            actor_state.audit_log,
            agent_id,
            op_name,
            op_tgt,
            audit_res,
            details,
            timestamp,
          )
          result
        }
      }
    }
  }
}

/// Execute the operation itself (step 4 — actual kernel action).
fn run_op(op: SyscallOp, agent_id: String) -> SyscallResult {
  case op {
    SpawnAgent(config) -> SyscallOk("spawned:agent_config=" <> config)
    KillAgent(target_id) -> SyscallOk("killed:" <> target_id)
    ReadWorld(pattern) -> SyscallOk("world_facts:pattern=" <> pattern)
    WriteWorld(content, confidence) ->
      SyscallOk(
        "fact_asserted:confidence="
        <> float_to_string(confidence)
        <> ":"
        <> content,
      )
    ReadFile(path) -> SyscallOk("file_content:path=" <> path)
    WriteFile(path, content) ->
      SyscallOk(
        "file_written:path="
        <> path
        <> ":bytes="
        <> int.to_string(string_length(content)),
      )
    Schedule(task_id, delay_ms) ->
      SyscallOk("scheduled:" <> task_id <> ":delay=" <> int.to_string(delay_ms))
    CancelSchedule(task_id) -> SyscallOk("cancelled:" <> task_id)
    GetBudget -> SyscallOk("budget:agent=" <> agent_id)
    EmitEvent(event_type, payload) ->
      SyscallOk("event_emitted:" <> event_type <> ":" <> payload)
  }
}

// ============================================================================
// FFI — String helpers
// ============================================================================

@external(erlang, "erlang", "byte_size")
fn string_length(s: String) -> Int

fn float_to_string(f: Float) -> String {
  // Use Erlang's io_lib:format to get a clean decimal representation
  // rather than scientific notation for values like 0.9
  do_float_to_string(f)
}

@external(erlang, "supernova_ledger_ffi", "format_float")
fn do_float_to_string(f: Float) -> String

fn argument_path(args: String) -> Option(String) {
  case json.parse(from: args, using: path_decoder()) {
    Ok(path) -> Some(path)
    Error(_) -> None
  }
}

fn path_decoder() -> decode.Decoder(String) {
  use path <- decode.field("path", decode.string)
  decode.success(path)
}

// ============================================================================
// Tool Pipeline
// ============================================================================

fn capability_denied(
  manifests: Dict(String, cap_types.CapabilityManifest),
  role: String,
  tool_name: String,
) -> Bool {
  case dict.get(manifests, role) {
    Ok(manifest) -> !cap_pure.allowed(manifest, tool_name)
    Error(_) ->
      // A role without an explicit manifest can only be admin. This keeps the
      // gateway closed by default while preserving old syscall tests.
      role != "admin"
  }
}

fn tool_touches_write(tool_name: String, args: String) -> Bool {
  tool_name == "file_system" && string.contains(args, "\"write\"")
}

fn tool_path_check(
  actor_state: ActorState,
  principal_id: String,
  tool_name: String,
  args: String,
) -> Result(Nil, String) {
  case argument_path(args) {
    None -> Ok(Nil)
    Some(path) ->
      case actor_state.workspace_policy {
        None -> Ok(Nil)
        Some(policy) -> {
          let op = case tool_touches_write(tool_name, args) {
            True -> policy_types.OpWrite
            False -> policy_types.OpRead
          }
          case policy_actor.authorize(policy, principal_id, op, path) {
            Ok(_) -> Ok(Nil)
            Error(reason) -> Error(reason)
          }
        }
      }
  }
}

fn check_tool_budget(
  actor_state: ActorState,
  principal_id: String,
) -> Result(Nil, String) {
  case actor_state.budget_policy {
    None -> Ok(Nil)
    Some(policy) -> {
      case
        budget_actor.check(
          policy,
          principal_id,
          budget_types.BudgetToolCallsHourly,
          1,
        )
      {
        Ok(_) -> Ok(Nil)
        Error(exceeded) -> Error(exceeded.message)
      }
    }
  }
}

fn run_tool(
  actor_state: ActorState,
  principal_id: String,
  role: String,
  tool_name: String,
  args: String,
  timestamp: Int,
) -> Result(String, String) {
  // 1. Capability manifest
  case capability_denied(actor_state.capability_manifests, role, tool_name) {
    True -> {
      audit_syscall(
        actor_state.audit_log,
        principal_id,
        "capability_denied",
        tool_name,
        audit_types.AuditDenied,
        "role=" <> role,
        timestamp,
      )
      Error("capability_denied: tool '" <> tool_name <> "' is not allowed")
    }
    False -> {
      // 2. Workspace policy (only when the tool touches a path)
      case tool_path_check(actor_state, principal_id, tool_name, args) {
        Error(reason) -> {
          audit_syscall(
            actor_state.audit_log,
            principal_id,
            "tool_call",
            tool_name,
            audit_types.AuditDenied,
            "workspace_policy: " <> reason,
            timestamp,
          )
          Error("Blocked: " <> reason)
        }
        Ok(_) -> {
          // 3. Budget (tool calls per hour)
          case check_tool_budget(actor_state, principal_id) {
            Error(reason) -> {
              audit_syscall(
                actor_state.audit_log,
                principal_id,
                "tool_call",
                tool_name,
                audit_types.AuditDenied,
                "budget_policy: " <> reason,
                timestamp,
              )
              Error(reason)
            }
            Ok(_) -> {
              // 4. Execute
              let result = actor_state.tool_executor(tool_name, args)

              // 5. Ledger
              case actor_state.budget_policy {
                Some(policy) ->
                  budget_actor.record_consumption(
                    policy,
                    principal_id,
                    budget_types.BudgetToolCallsHourly,
                    1,
                  )
                None -> Nil
              }

              // 6. Audit log
              let #(audit_result, details) = case result {
                Ok(_) -> #(audit_types.AuditSuccess, "ok")
                Error(reason) -> #(audit_types.AuditFailure, reason)
              }
              audit_syscall(
                actor_state.audit_log,
                principal_id,
                "tool_call",
                tool_name,
                audit_result,
                details,
                timestamp,
              )
              result
            }
          }
        }
      }
    }
  }
}

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  actor_state: ActorState,
  message: SyscallMessage,
) -> actor.Next(ActorState, SyscallMessage) {
  case message {
    InvokeTool(reply_to, principal_id, role, tool_name, args) -> {
      let timestamp = ffi_current_timestamp()
      let result =
        run_tool(actor_state, principal_id, role, tool_name, args, timestamp)
      actor.send(reply_to, result)
      actor.continue(actor_state)
    }

    Invoke(reply_to, agent_id, op) -> {
      let timestamp = ffi_current_timestamp()

      // Step 1: Authentication (pure)
      let #(new_state, dispatch_result, commands) =
        pure.dispatch(actor_state.state, agent_id, op, timestamp)

      // Execute audit commands for denied auth
      execute_commands(commands, actor_state.audit_log)

      let result = case dispatch_result {
        Error(reason) -> SyscallDenied(reason)
        Ok(approved_op) ->
          execute_op(
            ActorState(..actor_state, state: new_state),
            agent_id,
            approved_op,
            timestamp,
          )
      }

      actor.send(reply_to, result)
      actor.continue(ActorState(..actor_state, state: new_state))
    }

    RegisterAgent(reply_to, agent_id) -> {
      let new_state = pure.register(actor_state.state, agent_id)
      actor.send(reply_to, Nil)
      actor.continue(ActorState(..actor_state, state: new_state))
    }

    UnregisterAgent(reply_to, agent_id) -> {
      let new_state = pure.unregister(actor_state.state, agent_id)
      actor.send(reply_to, Nil)
      actor.continue(ActorState(..actor_state, state: new_state))
    }

    IsRegistered(reply_to, agent_id) -> {
      let registered = pure.is_registered(actor_state.state, agent_id)
      actor.send(reply_to, registered)
      actor.continue(actor_state)
    }

    GetCount(reply_to, agent_id) -> {
      let count = pure.get_count(actor_state.state, agent_id)
      actor.send(reply_to, count)
      actor.continue(actor_state)
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

/// Start the syscall gateway without any policy enforcement.
pub fn start() -> Result(SyscallGateway, actor.StartError) {
  start_with_policies(None, None, None)
}

/// Start the syscall gateway with optional policy and audit actors.
pub fn start_with_policies(
  workspace_policy: Option(policy_actor.WorkspacePolicy),
  budget_policy: Option(budget_actor.BudgetPolicy),
  audit_log: Option(audit_actor.AuditLog),
) -> Result(SyscallGateway, actor.StartError) {
  let initial =
    ActorState(
      state: types.initial_state(),
      workspace_policy: workspace_policy,
      budget_policy: budget_policy,
      audit_log: audit_log,
      capability_manifests: dict.new(),
      tool_executor: fn(_, _) { Error("tool executor not configured") },
    )

  start_with_state(initial)
}

/// Start the syscall gateway with capability manifests and a bounded tool
/// executor. Production uses this entry point for every tool call.
pub fn start_with_capabilities(
  workspace_policy: Option(policy_actor.WorkspacePolicy),
  budget_policy: Option(budget_actor.BudgetPolicy),
  audit_log: Option(audit_actor.AuditLog),
  capability_manifests: Dict(String, cap_types.CapabilityManifest),
  tool_executor: fn(String, String) -> Result(String, String),
) -> Result(SyscallGateway, actor.StartError) {
  let initial =
    ActorState(
      state: types.initial_state(),
      workspace_policy: workspace_policy,
      budget_policy: budget_policy,
      audit_log: audit_log,
      capability_manifests: capability_manifests,
      tool_executor: tool_executor,
    )
  start_with_state(initial)
}

fn start_with_state(
  initial: ActorState,
) -> Result(SyscallGateway, actor.StartError) {
  case
    actor.new(initial)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Invoke a concrete tool through the kernel policy pipeline.
///
/// Pipeline: capability manifest → workspace policy → hourly tool budget →
/// execution → ledger → audit log. Explicit 2 s timeout: callers must treat a
/// timeout as a denial.
pub fn invoke_tool(
  gw: SyscallGateway,
  principal_id: String,
  role: String,
  tool_name: String,
  args: String,
) -> Result(String, String) {
  case
    safe_call.call(gw, 2000, InvokeTool(_, principal_id, role, tool_name, args))
  {
    Ok(result) -> result
    Error(_) -> Error("kernel unavailable; tool call refused")
  }
}

/// Invoke a syscall on behalf of an agent.
///
/// Pipeline: authentication → WorkspacePolicy → BudgetPolicy → execution → AuditLog.
/// Returns SyscallDenied if any policy check fails, SyscallOk on success.
pub fn invoke(
  gw: SyscallGateway,
  agent_id: String,
  op: SyscallOp,
) -> SyscallResult {
  actor.call(gw, waiting: 5000, sending: Invoke(_, agent_id, op))
}

/// Register an agent to make syscalls through this gateway.
pub fn register_agent(gw: SyscallGateway, agent_id: String) -> Nil {
  actor.call(gw, waiting: 5000, sending: RegisterAgent(_, agent_id))
}

/// Unregister an agent from the syscall gateway.
pub fn unregister_agent(gw: SyscallGateway, agent_id: String) -> Nil {
  actor.call(gw, waiting: 5000, sending: UnregisterAgent(_, agent_id))
}

/// Check if an agent is registered.
pub fn is_registered(gw: SyscallGateway, agent_id: String) -> Bool {
  actor.call(gw, waiting: 5000, sending: IsRegistered(_, agent_id))
}

/// Get the syscall invocation count for an agent.
pub fn get_count(gw: SyscallGateway, agent_id: String) -> Int {
  actor.call(gw, waiting: 5000, sending: GetCount(_, agent_id))
}

/// Stop the syscall gateway actor.
pub fn stop(gw: SyscallGateway) -> Nil {
  actor.call(gw, waiting: 5000, sending: Stop)
}
