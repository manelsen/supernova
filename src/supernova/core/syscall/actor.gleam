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
import supernova/tools/agenda
import supernova/tools/buscar_conversa
import supernova/tools/computador
import supernova/tools/file_system
import supernova/tools/lembrar

// ============================================================================
// FFI — Timestamp (Erlang)
// ============================================================================

/// Get current timestamp in milliseconds.
@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

@external(erlang, "supernova_syscall_ffi", "unique_id")
fn ffi_unique_id() -> Int

// ============================================================================
// Types
// ============================================================================

/// Messages handled by the syscall gateway actor.
pub type SyscallMessage {
  /// Invoke a syscall on behalf of agent_id
  Invoke(reply_to: Subject(SyscallResult), agent_id: String, op: SyscallOp)
  /// Authorize a concrete tool call on behalf of a principal. On success the
  /// reply carries the executor: the tool runs in the caller's process, never
  /// inside the gateway, so a slow tool cannot hold other principals.
  AuthorizeTool(
    reply_to: Subject(Result(String, String)),
    principal_id: String,
    role: String,
    tool_name: String,
    args: String,
  )
  ClaimTool(
    reply_to: Subject(Result(ToolExecutor, String)),
    reservation_id: String,
  )
  PurgeExpiredReservations(reply_to: Subject(Nil), now: Int)
  CancelToolClaim(reply_to: Subject(Nil), reservation_id: String)
  /// Report the outcome of an authorized tool call (audit only).
  ToolCompleted(
    reservation_id: String,
    principal_id: String,
    tool_name: String,
    result: Result(String, String),
    timestamp: Int,
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

/// Executes an authorized tool call: `fn(tool_name, args_json)`.
pub type ToolExecutor =
  fn(String, String) -> Result(String, String)

type ToolReservation {
  ToolReservation(
    principal_id: String,
    tool_name: String,
    audit_target: String,
    expires_at: Int,
    /// The path the workspace policy authorized, inside the caller's own
    /// workspace. The claimed executor runs on this path, never on the raw one.
    authorized_path: Option(String),
    /// Whether the policy authorized a write. A read authorization never
    /// runs a write, whatever arguments the executor receives.
    authorized_write: Bool,
  )
}

type ClaimedTool {
  ClaimedTool(principal_id: String, charged_at: Int, audit_target: String)
}

const tool_reservation_ttl_ms = 5000

fn active_reservations(
  reservations: Dict(String, ToolReservation),
  now: Int,
) -> Dict(String, ToolReservation) {
  dict.filter(reservations, fn(_, reservation) { reservation.expires_at > now })
}

fn same_hour_bucket(first: Int, second: Int) -> Bool {
  hour_bucket(first) == hour_bucket(second)
}

fn hour_bucket(timestamp: Int) -> Int {
  case int.divide(timestamp, 3_600_000) {
    Ok(bucket) -> bucket
    Error(_) -> 0
  }
}

fn reserved_for(
  reservations: Dict(String, ToolReservation),
  principal_id: String,
) -> Int {
  reservations
  |> dict.values
  |> list.filter(fn(reservation) { reservation.principal_id == principal_id })
  |> list.length
}

/// Internal actor state: pure syscall state + optional policy/audit handles.
type ActorState {
  ActorState(
    state: SyscallState,
    workspace_policy: Option(policy_actor.WorkspacePolicy),
    budget_policy: Option(budget_actor.BudgetPolicy),
    audit_log: Option(audit_actor.AuditLog),
    capability_manifests: Dict(String, cap_types.CapabilityManifest),
    tool_executor: fn(String, String) -> Result(String, String),
    tool_reservations: Dict(String, ToolReservation),
    claimed_tools: Dict(String, ClaimedTool),
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
        None ->
          case dict.is_empty(actor_state.capability_manifests) {
            True -> Ok(path)
            False -> Error("workspace policy unavailable")
          }
      }
    }
    WriteFile(path, _) -> {
      case actor_state.workspace_policy {
        Some(policy) ->
          policy_actor.authorize(policy, agent_id, policy_types.OpWrite, path)
        None ->
          case dict.is_empty(actor_state.capability_manifests) {
            True -> Ok(path)
            False -> Error("workspace policy unavailable")
          }
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

/// Decided from the action exactly as the tool will read it. Arguments the
/// tool cannot read count as a write: the stricter check.
fn tool_touches_write(tool_name: String, args: String) -> Bool {
  tool_name == "file_system"
  && case file_system.action(args) {
    Ok(action) -> action == "write"
    Error(_) -> True
  }
}

fn tool_audit_target(tool_name: String, args: String) -> String {
  case tool_name {
    "file_system" ->
      case argument_path(args) {
        Some(path) -> path
        None -> tool_name
      }
    _ -> tool_name
  }
}

/// The executor handed to the caller of a claimed reservation. A file_system
/// call runs on the authorized path; an agenda call runs on the caller's own
/// agenda; buscar_conversa searches the caller's own conversations; a computador call carries the caller to the computer; everything
/// else keeps the configured executor.
fn claimed_executor(
  configured: ToolExecutor,
  reservation: ToolReservation,
) -> ToolExecutor {
  case reservation.tool_name, reservation.authorized_path {
    "file_system", Some(path) -> fn(_name, args) {
      file_system.execute_at(path, args, reservation.authorized_write)
    }
    "agenda", _ -> fn(_name, args) {
      agenda.execute(reservation.principal_id, args)
    }
    "buscar_conversa", _ -> fn(_name, args) {
      buscar_conversa.execute(reservation.principal_id, args)
    }
    "lembrar", _ -> fn(_name, args) {
      lembrar.execute(reservation.principal_id, args)
    }
    "computador", _ -> fn(_name, args) {
      computador.execute(reservation.principal_id, args)
    }
    _, _ -> configured
  }
}

fn tool_path_check(
  actor_state: ActorState,
  principal_id: String,
  tool_name: String,
  args: String,
) -> Result(Option(String), String) {
  // A computador path names a place inside the agent's own computer, not on
  // this host: the host workspace policy does not apply to it.
  let host_path = case tool_name {
    "computador" -> None
    _ -> argument_path(args)
  }
  case host_path {
    None -> Ok(None)
    Some(path) ->
      case actor_state.workspace_policy {
        None ->
          case dict.is_empty(actor_state.capability_manifests) {
            True -> Ok(None)
            False -> Error("workspace policy unavailable")
          }
        Some(policy) -> {
          let op = case tool_touches_write(tool_name, args) {
            True -> policy_types.OpWrite
            False -> policy_types.OpRead
          }
          case policy_actor.authorize(policy, principal_id, op, path) {
            Ok(full_path) -> Ok(Some(full_path))
            Error(reason) -> Error(reason)
          }
        }
      }
  }
}

fn check_tool_budget(
  actor_state: ActorState,
  principal_id: String,
  amount: Int,
) -> Result(Nil, String) {
  case actor_state.budget_policy {
    None -> Ok(Nil)
    Some(policy) -> {
      case
        budget_actor.check(
          policy,
          principal_id,
          budget_types.BudgetToolCallsHourly,
          amount,
        )
      {
        Ok(_) -> Ok(Nil)
        Error(exceeded) -> Error(exceeded.message)
      }
    }
  }
}

fn authorize_tool(
  actor_state: ActorState,
  principal_id: String,
  role: String,
  tool_name: String,
  args: String,
  timestamp: Int,
) -> #(Result(String, String), ActorState) {
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
      #(
        Error("capability_denied: tool '" <> tool_name <> "' is not allowed"),
        ActorState(
          ..actor_state,
          tool_reservations: active_reservations(
            actor_state.tool_reservations,
            timestamp,
          ),
        ),
      )
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
          #(
            Error("Blocked: " <> reason),
            ActorState(
              ..actor_state,
              tool_reservations: active_reservations(
                actor_state.tool_reservations,
                timestamp,
              ),
            ),
          )
        }
        Ok(authorized_path) -> {
          let reservations =
            active_reservations(actor_state.tool_reservations, timestamp)
          let reserved = reserved_for(reservations, principal_id)
          // 3. Budget (tool calls per hour), counting open reservations.
          case check_tool_budget(actor_state, principal_id, 1 + reserved) {
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
              #(
                Error(reason),
                ActorState(..actor_state, tool_reservations: reservations),
              )
            }
            Ok(_) -> {
              let reservation_id = "tool:" <> int.to_string(ffi_unique_id())
              let reservation =
                ToolReservation(
                  principal_id: principal_id,
                  tool_name: tool_name,
                  audit_target: tool_audit_target(tool_name, args),
                  expires_at: timestamp + tool_reservation_ttl_ms,
                  authorized_path: authorized_path,
                  authorized_write: tool_touches_write(tool_name, args),
                )
              // Execution is charged only when the caller claims the
              // reservation. Unclaimed authorizations expire for free.
              #(
                Ok(reservation_id),
                ActorState(
                  ..actor_state,
                  tool_reservations: dict.insert(
                    reservations,
                    reservation_id,
                    reservation,
                  ),
                ),
              )
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
    AuthorizeTool(reply_to, principal_id, role, tool_name, args) -> {
      let timestamp = ffi_current_timestamp()
      let #(result, next_state) =
        authorize_tool(
          actor_state,
          principal_id,
          role,
          tool_name,
          args,
          timestamp,
        )
      actor.send(reply_to, result)
      actor.continue(next_state)
    }

    ClaimTool(reply_to, reservation_id) -> {
      let timestamp = ffi_current_timestamp()
      let reservations =
        active_reservations(actor_state.tool_reservations, timestamp)
      case dict.get(reservations, reservation_id) {
        Error(_) -> {
          actor.send(reply_to, Error("authorization expired"))
          actor.continue(
            ActorState(..actor_state, tool_reservations: reservations),
          )
        }
        Ok(reservation) -> {
          let charge = case actor_state.budget_policy {
            Some(policy) ->
              budget_actor.try_record_consumption(
                policy,
                reservation.principal_id,
                budget_types.BudgetToolCallsHourly,
                1,
              )
            None -> Ok(Nil)
          }
          case charge {
            Ok(_) -> {
              actor.send(
                reply_to,
                Ok(claimed_executor(actor_state.tool_executor, reservation)),
              )
              actor.continue(
                ActorState(
                  ..actor_state,
                  tool_reservations: dict.delete(reservations, reservation_id),
                  claimed_tools: dict.insert(
                    actor_state.claimed_tools,
                    reservation_id,
                    ClaimedTool(
                      principal_id: reservation.principal_id,
                      charged_at: timestamp,
                      audit_target: reservation.audit_target,
                    ),
                  ),
                ),
              )
            }
            Error(_) -> {
              audit_syscall(
                actor_state.audit_log,
                reservation.principal_id,
                "tool_claim",
                reservation.tool_name,
                audit_types.AuditDenied,
                "budget unavailable",
                timestamp,
              )
              actor.send(
                reply_to,
                Error("budget unavailable; tool call refused"),
              )
              actor.continue(
                ActorState(..actor_state, tool_reservations: reservations),
              )
            }
          }
        }
      }
    }

    CancelToolClaim(reply_to, reservation_id) -> {
      let next_state = case
        dict.get(actor_state.tool_reservations, reservation_id)
      {
        Ok(_) ->
          ActorState(
            ..actor_state,
            tool_reservations: dict.delete(
              actor_state.tool_reservations,
              reservation_id,
            ),
          )
        Error(_) ->
          case dict.get(actor_state.claimed_tools, reservation_id) {
            Ok(ClaimedTool(principal_id, charged_at, _)) -> {
              case
                actor_state.budget_policy,
                same_hour_bucket(charged_at, ffi_current_timestamp())
              {
                Some(policy), True ->
                  budget_actor.record_consumption(
                    policy,
                    principal_id,
                    budget_types.BudgetToolCallsHourly,
                    -1,
                  )
                _, _ -> Nil
              }
              ActorState(
                ..actor_state,
                claimed_tools: dict.delete(
                  actor_state.claimed_tools,
                  reservation_id,
                ),
              )
            }
            Error(_) -> actor_state
          }
      }
      actor.send(reply_to, Nil)
      actor.continue(next_state)
    }

    ToolCompleted(reservation_id, principal_id, tool_name, result, timestamp) -> {
      let #(audit_result, details) = case result {
        Ok(_) -> #(audit_types.AuditSuccess, "ok")
        Error(reason) -> #(audit_types.AuditFailure, reason)
      }
      let audit_target = case
        dict.get(actor_state.claimed_tools, reservation_id)
      {
        Ok(ClaimedTool(_, _, target)) -> target
        Error(_) -> tool_name
      }
      audit_syscall(
        actor_state.audit_log,
        principal_id,
        "tool_call",
        audit_target,
        audit_result,
        details,
        timestamp,
      )
      actor.continue(
        ActorState(
          ..actor_state,
          claimed_tools: dict.delete(actor_state.claimed_tools, reservation_id),
        ),
      )
    }

    PurgeExpiredReservations(reply_to, now) -> {
      actor.send(reply_to, Nil)
      actor.continue(
        ActorState(
          ..actor_state,
          tool_reservations: active_reservations(
            actor_state.tool_reservations,
            now,
          ),
        ),
      )
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
      tool_reservations: dict.new(),
      claimed_tools: dict.new(),
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
      tool_reservations: dict.new(),
      claimed_tools: dict.new(),
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
    safe_call.call(gw, 2000, AuthorizeTool(
      _,
      principal_id,
      role,
      tool_name,
      args,
    ))
  {
    Error(_) -> Error("kernel unavailable; tool call refused")
    Ok(Error(reason)) -> Error(reason)
    Ok(Ok(reservation_id)) ->
      case safe_call.call(gw, 2000, ClaimTool(_, reservation_id)) {
        Ok(Ok(execute)) -> {
          let result = execute(tool_name, args)
          process.send(
            gw,
            ToolCompleted(
              reservation_id,
              principal_id,
              tool_name,
              result,
              ffi_current_timestamp(),
            ),
          )
          result
        }
        Ok(Error(reason)) -> Error(reason)
        Error(_) -> {
          cancel_tool_claim(gw, reservation_id)
          Error("authorization expired")
        }
      }
  }
}

/// Expire reservations for deterministic tests.
pub fn expire_tool_reservations_for_test(gw: SyscallGateway, now: Int) -> Nil {
  let _ = safe_call.call(gw, 2000, PurgeExpiredReservations(_, now))
  Nil
}

/// Authorize a tool without claiming it. The caller must call
/// `claim_tool_call` before executing; unclaimed reservations expire.
pub fn authorize_tool_call(
  gw: SyscallGateway,
  principal_id: String,
  role: String,
  tool_name: String,
  args: String,
) -> Result(String, String) {
  case
    safe_call.call(gw, 2000, AuthorizeTool(
      _,
      principal_id,
      role,
      tool_name,
      args,
    ))
  {
    Ok(result) -> result
    Error(_) -> Error("kernel unavailable; tool call refused")
  }
}

/// Cancel a claim that was not executed. Refunds the budget if the claim had
/// already been processed, or removes the reservation if it is still open.
pub fn cancel_tool_claim(gw: SyscallGateway, reservation_id: String) -> Nil {
  let _ = safe_call.call(gw, 2000, CancelToolClaim(_, reservation_id))
  Nil
}

/// Claim an authorization and charge exactly one tool call.
pub fn claim_tool_call(
  gw: SyscallGateway,
  reservation_id: String,
) -> Result(ToolExecutor, String) {
  case safe_call.call(gw, 2000, ClaimTool(_, reservation_id)) {
    Ok(result) -> result
    Error(_) -> Error("authorization expired")
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
