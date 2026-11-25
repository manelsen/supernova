//// Syscall — Actor Tests
////
//// Integration tests for the syscall gateway actor.
//// Tests the full pipeline: authentication → WorkspacePolicy → BudgetPolicy → execution → AuditLog.

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import supernova/core/audit_log/actor as audit_actor
import supernova/core/audit_log/types as audit_types
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/budget_policy/types as budget_types
import supernova/core/capability_manifest/types as cap_types
import supernova/core/syscall/actor
import supernova/core/syscall/types.{
  CancelSchedule, EmitEvent, GetBudget, KillAgent, ReadFile, ReadWorld, Schedule,
  SpawnAgent, SyscallDenied, SyscallFailed, SyscallOk, WriteFile, WriteWorld,
}
import supernova/core/tool_runner
import supernova/core/workspace_policy/actor as policy_actor
import test_budget
import test_workspace

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Actor Lifecycle Tests
// ============================================================================

pub fn start_and_stop_test() {
  let assert Ok(gw) = actor.start()
  actor.stop(gw)
  process.sleep(100)
}

pub fn start_with_policies_and_stop_test() {
  let assert Ok(gw) =
    actor.start_with_policies(option.None, option.None, option.None)
  actor.stop(gw)
  process.sleep(100)
}

pub fn capabilities_without_workspace_policy_deny_file_operations_test() {
  let manifests =
    dict.from_list([
      #(
        "admin",
        cap_types.CapabilityManifest(
          allowed_tools: ["file_system"],
          denied_tools: [],
        ),
      ),
    ])
  let assert Ok(gw) =
    actor.start_with_capabilities(
      option.None,
      option.None,
      option.None,
      manifests,
      fn(_, _) { Ok("should not run") },
    )

  actor.register_agent(gw, "agent_1")
  actor.invoke(gw, "agent_1", ReadFile("src/main.gleam"))
  |> should.equal(SyscallDenied("workspace policy unavailable"))

  actor.invoke_tool(
    gw,
    "agent_1",
    "admin",
    "file_system",
    "{\"action\":\"read\",\"path\":\"src/main.gleam\"}",
  )
  |> should.equal(Error("Blocked: workspace policy unavailable"))

  actor.stop(gw)
}

/// PRD-E, E-04: with capability manifests (production) and no budget
/// policy, the gateway denies instead of letting calls through uncounted.
pub fn capabilities_without_budget_policy_deny_tool_calls_test() {
  let manifests =
    dict.from_list([
      #(
        "admin",
        cap_types.CapabilityManifest(allowed_tools: ["*"], denied_tools: []),
      ),
    ])
  let assert Ok(gw) =
    actor.start_with_capabilities(
      option.None,
      option.None,
      option.None,
      manifests,
      fn(_, _) { Ok("should not run") },
    )
  actor.register_agent(gw, "agent_1")
  actor.invoke_tool(gw, "agent_1", "admin", "web_fetch", "{\"url\":\"x\"}")
  |> should.equal(Error("budget policy unavailable"))
  actor.stop(gw)
}

/// The same rule for syscalls that are not tools.
pub fn capabilities_without_budget_policy_deny_syscalls_test() {
  let manifests =
    dict.from_list([
      #(
        "admin",
        cap_types.CapabilityManifest(allowed_tools: ["*"], denied_tools: []),
      ),
    ])
  let assert Ok(without) =
    actor.start_with_capabilities(
      option.None,
      option.None,
      option.None,
      manifests,
      fn(_, _) { Ok("unused") },
    )
  actor.register_agent(without, "agent_1")
  actor.invoke(without, "agent_1", GetBudget)
  |> should.equal(SyscallDenied("budget policy unavailable"))
  actor.stop(without)

  let assert Ok(with) =
    actor.start_with_capabilities(
      option.None,
      option.Some(test_budget.unlimited()),
      option.None,
      manifests,
      fn(_, _) { Ok("unused") },
    )
  actor.register_agent(with, "agent_1")
  case actor.invoke(with, "agent_1", GetBudget) {
    SyscallDenied(reason) -> panic as reason
    _ -> Nil
  }
  actor.stop(with)
}

fn claim_gateway(
  budget_limit: Int,
) -> #(actor.SyscallGateway, budget_actor.BudgetPolicy) {
  let assert Ok(budget) =
    budget_actor.start_with_config(
      budget_types.BudgetConfig(
        tokens_per_hour: -1,
        tool_calls_per_minute: -1,
        tool_calls_per_hour: budget_limit,
        max_recursion_depth: 3,
        max_sub_agents: 3,
      ),
      20,
    )
  let manifests =
    dict.from_list([
      #(
        "admin",
        cap_types.CapabilityManifest(allowed_tools: ["*"], denied_tools: []),
      ),
    ])
  let assert Ok(gateway) =
    actor.start_with_capabilities(
      option.None,
      option.Some(budget),
      option.None,
      manifests,
      fn(_, _) { Ok("ran") },
    )
  #(gateway, budget)
}

pub fn unclaimed_tool_authorization_does_not_charge_test() {
  let #(gateway, budget) = claim_gateway(1)
  let assert Ok(reservation_id) =
    actor.authorize_tool_call(gateway, "agent_1", "admin", "web", "{}")

  budget_actor.get_consumption(
    budget,
    "agent_1",
    budget_types.BudgetToolCallsHourly,
  )
  |> should.equal(0)

  let assert Ok(execute) = actor.claim_tool_call(gateway, reservation_id)
  execute("web", "{}") |> should.equal(Ok("ran"))

  budget_actor.get_consumption(
    budget,
    "agent_1",
    budget_types.BudgetToolCallsHourly,
  )
  |> should.equal(1)

  actor.stop(gateway)
  budget_actor.stop(budget)
}

pub fn parallel_authorizations_share_one_credit_test() {
  let #(gateway, budget) = claim_gateway(1)

  let assert Ok(reservation_id) =
    actor.authorize_tool_call(gateway, "agent_1", "admin", "web", "{}")
  actor.authorize_tool_call(gateway, "agent_1", "admin", "web", "{}")
  |> should.be_error()

  let assert Ok(_) = actor.claim_tool_call(gateway, reservation_id)

  actor.authorize_tool_call(gateway, "agent_1", "admin", "web", "{}")
  |> should.be_error()

  actor.stop(gateway)
  budget_actor.stop(budget)
}

pub fn expired_tool_authorization_does_not_charge_test() {
  let #(gateway, budget) = claim_gateway(1)
  let assert Ok(reservation_id) =
    actor.authorize_tool_call(gateway, "agent_1", "admin", "web", "{}")

  actor.expire_tool_reservations_for_test(gateway, 9_999_999_999_999)
  actor.claim_tool_call(gateway, reservation_id)
  |> should.be_error()

  budget_actor.get_consumption(
    budget,
    "agent_1",
    budget_types.BudgetToolCallsHourly,
  )
  |> should.equal(0)

  actor.stop(gateway)
  budget_actor.stop(budget)
}

// ============================================================================
// Registration Tests
// ============================================================================

pub fn register_and_is_registered_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let is_reg = actor.is_registered(gw, "agent_1")
  is_reg |> should.be_true
  actor.stop(gw)
  process.sleep(100)
}

pub fn unregistered_agent_not_found_test() {
  let assert Ok(gw) = actor.start()
  let is_reg = actor.is_registered(gw, "ghost")
  is_reg |> should.be_false
  actor.stop(gw)
  process.sleep(100)
}

pub fn unregister_removes_agent_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  actor.unregister_agent(gw, "agent_1")
  let is_reg = actor.is_registered(gw, "agent_1")
  is_reg |> should.be_false
  actor.stop(gw)
  process.sleep(100)
}

// ============================================================================
// Count Tracking Tests
// ============================================================================

pub fn get_count_after_registration_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let count = actor.get_count(gw, "agent_1")
  count |> should.equal(0)
  actor.stop(gw)
  process.sleep(100)
}

pub fn get_count_after_syscall_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let _ = actor.invoke(gw, "agent_1", GetBudget)
  let count = actor.get_count(gw, "agent_1")
  count |> should.equal(1)
  actor.stop(gw)
  process.sleep(100)
}

// ============================================================================
// SpawnAgent Tests
// ============================================================================

pub fn spawn_agent_registered_reaches_execution_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", SpawnAgent("{\"type\":\"worker\"}"))
  // Policies, counting and audit ran; the operation itself is not
  // wired to a kernel action and says so (PRD-E, E-05).
  result |> should.equal(SyscallFailed("not implemented: spawn_agent"))
  actor.stop(gw)
  process.sleep(100)
}

pub fn spawn_agent_unregistered_denied_test() {
  let assert Ok(gw) = actor.start()
  let result = actor.invoke(gw, "ghost", SpawnAgent("{}"))
  case result {
    SyscallDenied(reason) -> {
      reason |> should.equal("Agent not registered: ghost")
    }
    _ -> should.fail()
  }
  actor.stop(gw)
  process.sleep(100)
}

// ============================================================================
// KillAgent Tests
// ============================================================================

pub fn kill_agent_registered_reaches_execution_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", KillAgent("agent_2"))
  // Policies, counting and audit ran; the operation itself is not
  // wired to a kernel action and says so (PRD-E, E-05).
  result |> should.equal(SyscallFailed("not implemented: kill_agent"))
  actor.stop(gw)
  process.sleep(100)
}

pub fn kill_agent_unregistered_denied_test() {
  let assert Ok(gw) = actor.start()
  let result = actor.invoke(gw, "ghost", KillAgent("target"))
  case result {
    SyscallDenied(reason) ->
      reason |> should.equal("Agent not registered: ghost")
    _ -> should.fail()
  }
  actor.stop(gw)
  process.sleep(100)
}

// ============================================================================
// ReadWorld Tests
// ============================================================================

pub fn read_world_registered_reaches_execution_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", ReadWorld("sky"))
  // Policies, counting and audit ran; the operation itself is not
  // wired to a kernel action and says so (PRD-E, E-05).
  result |> should.equal(SyscallFailed("not implemented: read_world"))
  actor.stop(gw)
  process.sleep(100)
}

pub fn read_world_unregistered_denied_test() {
  let assert Ok(gw) = actor.start()
  let result = actor.invoke(gw, "ghost", ReadWorld("facts"))
  case result {
    SyscallDenied(reason) ->
      reason |> should.equal("Agent not registered: ghost")
    _ -> should.fail()
  }
  actor.stop(gw)
  process.sleep(100)
}

// ============================================================================
// WriteWorld Tests
// ============================================================================

pub fn write_world_registered_reaches_execution_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", WriteWorld("sky is blue", 0.9))
  // Policies, counting and audit ran; the operation itself is not
  // wired to a kernel action and says so (PRD-E, E-05).
  result |> should.equal(SyscallFailed("not implemented: write_world"))
  actor.stop(gw)
  process.sleep(100)
}

pub fn write_world_unregistered_denied_test() {
  let assert Ok(gw) = actor.start()
  let result = actor.invoke(gw, "ghost", WriteWorld("content", 0.5))
  case result {
    SyscallDenied(reason) ->
      reason |> should.equal("Agent not registered: ghost")
    _ -> should.fail()
  }
  actor.stop(gw)
  process.sleep(100)
}

// ============================================================================
// ReadFile Tests
// ============================================================================

pub fn read_file_registered_reaches_execution_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", ReadFile("src/main.gleam"))
  // Policies, counting and audit ran; the operation itself is not
  // wired to a kernel action and says so (PRD-E, E-05).
  result |> should.equal(SyscallFailed("not implemented: read_file"))
  actor.stop(gw)
  process.sleep(100)
}

pub fn read_file_unregistered_denied_test() {
  let assert Ok(gw) = actor.start()
  let result = actor.invoke(gw, "ghost", ReadFile("secret.txt"))
  case result {
    SyscallDenied(reason) ->
      reason |> should.equal("Agent not registered: ghost")
    _ -> should.fail()
  }
  actor.stop(gw)
  process.sleep(100)
}

// ============================================================================
// WriteFile Tests
// ============================================================================

pub fn write_file_registered_reaches_execution_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", WriteFile("out.txt", "hello world"))
  // Policies, counting and audit ran; the operation itself is not
  // wired to a kernel action and says so (PRD-E, E-05).
  result |> should.equal(SyscallFailed("not implemented: write_file"))
  actor.stop(gw)
  process.sleep(100)
}

pub fn write_file_unregistered_denied_test() {
  let assert Ok(gw) = actor.start()
  let result = actor.invoke(gw, "ghost", WriteFile("out.txt", "data"))
  case result {
    SyscallDenied(reason) ->
      reason |> should.equal("Agent not registered: ghost")
    _ -> should.fail()
  }
  actor.stop(gw)
  process.sleep(100)
}

// ============================================================================
// Schedule Tests
// ============================================================================

pub fn schedule_registered_reaches_execution_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", Schedule("task_42", 5000))
  // Policies, counting and audit ran; the operation itself is not
  // wired to a kernel action and says so (PRD-E, E-05).
  result |> should.equal(SyscallFailed("not implemented: schedule"))
  actor.stop(gw)
  process.sleep(100)
}

pub fn schedule_unregistered_denied_test() {
  let assert Ok(gw) = actor.start()
  let result = actor.invoke(gw, "ghost", Schedule("task_1", 1000))
  case result {
    SyscallDenied(reason) ->
      reason |> should.equal("Agent not registered: ghost")
    _ -> should.fail()
  }
  actor.stop(gw)
  process.sleep(100)
}

// ============================================================================
// CancelSchedule Tests
// ============================================================================

pub fn cancel_schedule_registered_reaches_execution_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", CancelSchedule("task_42"))
  // Policies, counting and audit ran; the operation itself is not
  // wired to a kernel action and says so (PRD-E, E-05).
  result |> should.equal(SyscallFailed("not implemented: cancel_schedule"))
  actor.stop(gw)
  process.sleep(100)
}

pub fn cancel_schedule_unregistered_denied_test() {
  let assert Ok(gw) = actor.start()
  let result = actor.invoke(gw, "ghost", CancelSchedule("task_1"))
  case result {
    SyscallDenied(reason) ->
      reason |> should.equal("Agent not registered: ghost")
    _ -> should.fail()
  }
  actor.stop(gw)
  process.sleep(100)
}

// ============================================================================
// GetBudget Tests
// ============================================================================

pub fn get_budget_registered_reaches_execution_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", GetBudget)
  // Policies, counting and audit ran; the operation itself is not
  // wired to a kernel action and says so (PRD-E, E-05).
  result |> should.equal(SyscallFailed("not implemented: get_budget"))
  actor.stop(gw)
  process.sleep(100)
}

pub fn get_budget_unregistered_denied_test() {
  let assert Ok(gw) = actor.start()
  let result = actor.invoke(gw, "ghost", GetBudget)
  case result {
    SyscallDenied(reason) ->
      reason |> should.equal("Agent not registered: ghost")
    _ -> should.fail()
  }
  actor.stop(gw)
  process.sleep(100)
}

// ============================================================================
// EmitEvent Tests
// ============================================================================

pub fn emit_event_registered_reaches_execution_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result =
    actor.invoke(gw, "agent_1", EmitEvent("task_complete", "{\"id\":1}"))
  // Policies, counting and audit ran; the operation itself is not
  // wired to a kernel action and says so (PRD-E, E-05).
  result |> should.equal(SyscallFailed("not implemented: emit_event"))
  actor.stop(gw)
  process.sleep(100)
}

pub fn emit_event_unregistered_denied_test() {
  let assert Ok(gw) = actor.start()
  let result = actor.invoke(gw, "ghost", EmitEvent("ev", "{}"))
  case result {
    SyscallDenied(reason) ->
      reason |> should.equal("Agent not registered: ghost")
    _ -> should.fail()
  }
  actor.stop(gw)
  process.sleep(100)
}

// ============================================================================
// All Syscalls Increment Count (Denial Also Counts)
// ============================================================================

pub fn denied_syscall_increments_count_test() {
  let assert Ok(gw) = actor.start()
  // Unregistered agent tries to call
  let _ = actor.invoke(gw, "ghost", GetBudget)
  let count = actor.get_count(gw, "ghost")
  count |> should.equal(1)
  actor.stop(gw)
  process.sleep(100)
}

pub fn multiple_syscalls_increment_count_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let _ = actor.invoke(gw, "agent_1", GetBudget)
  let _ = actor.invoke(gw, "agent_1", EmitEvent("test", "data"))
  let _ = actor.invoke(gw, "agent_1", GetBudget)
  let count = actor.get_count(gw, "agent_1")
  count |> should.equal(3)
  actor.stop(gw)
  process.sleep(100)
}

pub fn cancelled_claim_refunds_budget_test() {
  let #(gateway, budget) = claim_gateway(1)
  let assert Ok(reservation_id) =
    actor.authorize_tool_call(gateway, "agent_1", "admin", "web", "{}")

  let assert Ok(_) = actor.claim_tool_call(gateway, reservation_id)
  budget_actor.get_consumption(
    budget,
    "agent_1",
    budget_types.BudgetToolCallsHourly,
  )
  |> should.equal(1)

  actor.cancel_tool_claim(gateway, reservation_id)
  budget_actor.get_consumption(
    budget,
    "agent_1",
    budget_types.BudgetToolCallsHourly,
  )
  |> should.equal(0)

  actor.claim_tool_call(gateway, reservation_id) |> should.be_error()

  actor.stop(gateway)
  budget_actor.stop(budget)
}

pub fn thousand_tool_reservations_have_unique_ids_test() {
  let #(gateway, budget) = claim_gateway(-1)
  let first =
    list.repeat(Nil, 500)
    |> list.map(fn(_) {
      let assert Ok(reservation_id) =
        actor.authorize_tool_call(gateway, "agent_1", "admin", "web", "{}")
      reservation_id
    })
  list.take(first, 20)
  |> list.each(fn(reservation_id) {
    let assert Ok(_) = actor.claim_tool_call(gateway, reservation_id)
  })
  actor.expire_tool_reservations_for_test(gateway, 9_999_999_999_999)
  let second =
    list.repeat(Nil, 500)
    |> list.map(fn(_) {
      let assert Ok(reservation_id) =
        actor.authorize_tool_call(gateway, "agent_1", "admin", "web", "{}")
      reservation_id
    })
  let ids = list.append(first, second)
  let unique = dict.from_list(list.map(ids, fn(id) { #(id, True) }))
  dict.size(unique) |> should.equal(1000)

  actor.stop(gateway)
  budget_actor.stop(budget)
}

pub fn claim_is_refused_when_budget_is_unavailable_test() {
  let #(gateway, budget) = claim_gateway(1)
  let assert Ok(reservation_id) =
    actor.authorize_tool_call(gateway, "agent_1", "admin", "web", "{}")

  budget_actor.stop(budget)
  process.sleep(20)

  actor.claim_tool_call(gateway, reservation_id)
  |> should.equal(Error("budget unavailable; tool call refused"))

  actor.stop(gateway)
}

pub fn completed_tool_cannot_be_refunded_test() {
  let #(gateway, budget) = claim_gateway(1)
  let assert Ok(reservation_id) =
    actor.authorize_tool_call(gateway, "agent_1", "admin", "web", "{}")
  let assert Ok(_) = actor.claim_tool_call(gateway, reservation_id)

  process.send(
    gateway,
    actor.ToolCompleted(reservation_id, "agent_1", "web", Ok("ran"), 1),
  )
  actor.cancel_tool_claim(gateway, reservation_id)

  budget_actor.get_consumption(
    budget,
    "agent_1",
    budget_types.BudgetToolCallsHourly,
  )
  |> should.equal(1)

  actor.stop(gateway)
  budget_actor.stop(budget)
}

pub fn late_claim_retry_charges_once_test() {
  let #(gateway, budget) = claim_gateway(1)
  let assert Ok(reservation_id) =
    actor.authorize_tool_call(gateway, "agent_1", "admin", "web", "{}")
  let assert Ok(_) = actor.claim_tool_call(gateway, reservation_id)

  // The first claim removed the reservation and charged once. A late retry
  // with the same id must fail instead of charging again.
  actor.claim_tool_call(gateway, reservation_id)
  |> should.equal(Error("authorization expired"))

  budget_actor.get_consumption(
    budget,
    "agent_1",
    budget_types.BudgetToolCallsHourly,
  )
  |> should.equal(1)

  actor.stop(gateway)
  budget_actor.stop(budget)
}

pub fn principal_workspace_denies_self_and_other_agent_test() {
  let assert Ok(policy) = policy_actor.start("/data/agents")
  let assert Ok(gw) =
    actor.start_with_policies(option.Some(policy), option.None, option.None)
  actor.register_agent(gw, "telegram:123")

  case actor.invoke(gw, "telegram:123", WriteFile("notes.txt", "hello")) {
    // Allowed by the workspace policy; the operation itself is not wired.
    SyscallFailed(_reason) -> Nil
    SyscallDenied(_reason) -> should.fail()
    SyscallOk(_) -> should.fail()
  }

  case actor.invoke(gw, "telegram:123", ReadFile("../self/core.json")) {
    SyscallDenied(reason) ->
      string.contains(reason, "Path traversal blocked") |> should.be_true()
    _ -> should.fail()
  }

  case
    actor.invoke(
      gw,
      "telegram:123",
      ReadFile("/data/agents/telegram_123/self/core.json"),
    )
  {
    SyscallDenied(_) -> Nil
    _ -> should.fail()
  }

  case
    actor.invoke(
      gw,
      "telegram:123",
      ReadFile("/data/agents/discord_123/workspace/notes.txt"),
    )
  {
    SyscallDenied(_) -> Nil
    _ -> should.fail()
  }

  actor.stop(gw)
}

pub fn tool_completion_audits_the_authorized_path_test() {
  use root <- test_workspace.with_isolated_workspace("syscall-audit")
  let assert Ok(log) = audit_actor.start(root)
  let assert Ok(gw) =
    actor.start_with_capabilities(
      option.None,
      option.None,
      option.Some(log),
      dict.new(),
      fn(_, _) { Ok("ran") },
    )
  let path = "agents/sim_alice/self/state.json"
  actor.invoke_tool(
    gw,
    "sim:alice",
    "admin",
    "file_system",
    "{\"action\":\"read\",\"path\":\"" <> path <> "\"}",
  )
  |> should.equal(Ok("ran"))
  process.sleep(50)
  audit_actor.get_all(log)
  |> list.any(fn(entry) {
    entry.operation == "tool_call"
    && entry.target == path
    && entry.result == audit_types.AuditSuccess
  })
  |> should.be_true()
  actor.stop(gw)
  audit_actor.stop(log)
}

// PRD-F, F-02 (I3): a call cut by its time limit, or whose turn died, is
// still completed once in the audit, with what happened.

fn stuck_gateway(log) {
  let manifests =
    dict.from_list([
      #(
        "admin",
        cap_types.CapabilityManifest(allowed_tools: ["web"], denied_tools: []),
      ),
    ])
  let assert Ok(gw) =
    actor.start_with_capabilities(
      option.None,
      option.Some(test_budget.unlimited()),
      option.Some(log),
      manifests,
      fn(_, _) {
        process.sleep_forever()
        Ok("unreachable")
      },
    )
  gw
}

fn audited_outcome(
  log,
  tries: Int,
) -> Result(#(audit_types.AuditResult, String), Nil) {
  let found =
    audit_actor.get_all(log)
    |> list.find(fn(entry) { entry.operation == "tool_call" })
  case found, tries {
    Ok(entry), _ -> Ok(#(entry.result, entry.details))
    Error(Nil), 0 -> Error(Nil)
    Error(Nil), _ -> {
      process.sleep(10)
      audited_outcome(log, tries - 1)
    }
  }
}

pub fn a_call_cut_at_its_limit_is_audited_as_timeout_test() {
  use root <- test_workspace.with_isolated_workspace("syscall-timeout")
  let assert Ok(log) = audit_actor.start(root)
  let gw = stuck_gateway(log)
  tool_runner.run(100, fn() {
    actor.invoke_tool(gw, "agent_1", "admin", "web", "{\"url\":\"x\"}")
  })
  |> should.equal(tool_runner.TimedOut(100))
  audited_outcome(log, 200)
  |> should.equal(Ok(#(audit_types.AuditFailure, "timeout")))
  // The gateway forgets the claim.
  actor.claimed_count_for_test(gw) |> should.equal(0)
  actor.stop(gw)
  audit_actor.stop(log)
}

pub fn a_call_whose_turn_died_is_audited_as_cancelled_test() {
  use root <- test_workspace.with_isolated_workspace("syscall-cancel")
  let assert Ok(log) = audit_actor.start(root)
  let gw = stuck_gateway(log)
  let turn =
    process.spawn_unlinked(fn() {
      tool_runner.run(60_000, fn() {
        actor.invoke_tool(gw, "agent_1", "admin", "web", "{\"url\":\"x\"}")
      })
    })
  // The call is running once its claim exists; then the turn dies.
  wait_claimed(gw, 200)
  process.kill(turn)
  audited_outcome(log, 200)
  |> should.equal(Ok(#(audit_types.AuditFailure, "cancelado")))
  actor.stop(gw)
  audit_actor.stop(log)
}

fn wait_claimed(gw, tries: Int) -> Nil {
  case actor.claimed_count_for_test(gw) > 0, tries {
    True, _ -> Nil
    False, 0 -> panic as "the call never got its claim"
    False, _ -> {
      process.sleep(5)
      wait_claimed(gw, tries - 1)
    }
  }
}

pub fn a_call_killed_from_outside_is_audited_as_interrupted_test() {
  use root <- test_workspace.with_isolated_workspace("syscall-killed")
  let assert Ok(log) = audit_actor.start(root)
  let manifests =
    dict.from_list([
      #(
        "admin",
        cap_types.CapabilityManifest(allowed_tools: ["web"], denied_tools: []),
      ),
    ])
  let assert Ok(gw) =
    actor.start_with_capabilities(
      option.None,
      option.Some(test_budget.unlimited()),
      option.Some(log),
      manifests,
      fn(_, _) {
        process.kill(process.self())
        Ok("unreachable")
      },
    )
  let _ =
    tool_runner.run(1000, fn() {
      actor.invoke_tool(gw, "agent_1", "admin", "web", "{\"url\":\"x\"}")
    })
  let assert Ok(#(audit_types.AuditFailure, details)) =
    audited_outcome(log, 200)
  string.starts_with(details, "interrompida:") |> should.be_true
  actor.stop(gw)
  audit_actor.stop(log)
}
