//// Syscall — Actor Tests
////
//// Integration tests for the syscall gateway actor.
//// Tests the full pipeline: authentication → WorkspacePolicy → BudgetPolicy → execution → AuditLog.

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option
import gleeunit
import gleeunit/should
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/budget_policy/types as budget_types
import supernova/core/capability_manifest/types as cap_types
import supernova/core/syscall/actor
import supernova/core/syscall/types.{
  CancelSchedule, EmitEvent, GetBudget, KillAgent, ReadFile, ReadWorld, Schedule,
  SpawnAgent, SyscallDenied, SyscallFailed, SyscallOk, WriteFile, WriteWorld,
}

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

pub fn spawn_agent_registered_ok_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", SpawnAgent("{\"type\":\"worker\"}"))
  case result {
    SyscallOk(data) -> {
      data |> should.equal("spawned:agent_config={\"type\":\"worker\"}")
    }
    SyscallDenied(_reason) -> {
      should.fail()
    }
    SyscallFailed(_message) -> {
      should.fail()
    }
  }
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

pub fn kill_agent_registered_ok_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", KillAgent("agent_2"))
  case result {
    SyscallOk(data) -> data |> should.equal("killed:agent_2")
    SyscallDenied(_) -> should.fail()
    SyscallFailed(_) -> should.fail()
  }
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

pub fn read_world_registered_ok_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", ReadWorld("sky"))
  case result {
    SyscallOk(data) -> data |> should.equal("world_facts:pattern=sky")
    SyscallDenied(_) -> should.fail()
    SyscallFailed(_) -> should.fail()
  }
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

pub fn write_world_registered_ok_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", WriteWorld("sky is blue", 0.9))
  case result {
    SyscallOk(data) -> {
      data |> should.equal("fact_asserted:confidence=0.9:sky is blue")
    }
    SyscallDenied(_) -> should.fail()
    SyscallFailed(_) -> should.fail()
  }
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

pub fn read_file_registered_ok_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", ReadFile("src/main.gleam"))
  case result {
    SyscallOk(data) -> data |> should.equal("file_content:path=src/main.gleam")
    SyscallDenied(_) -> should.fail()
    SyscallFailed(_) -> should.fail()
  }
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

pub fn write_file_registered_ok_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", WriteFile("out.txt", "hello world"))
  case result {
    SyscallOk(data) -> {
      data |> should.equal("file_written:path=out.txt:bytes=11")
    }
    SyscallDenied(_) -> should.fail()
    SyscallFailed(_) -> should.fail()
  }
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

pub fn schedule_registered_ok_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", Schedule("task_42", 5000))
  case result {
    SyscallOk(data) -> data |> should.equal("scheduled:task_42:delay=5000")
    SyscallDenied(_) -> should.fail()
    SyscallFailed(_) -> should.fail()
  }
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

pub fn cancel_schedule_registered_ok_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", CancelSchedule("task_42"))
  case result {
    SyscallOk(data) -> data |> should.equal("cancelled:task_42")
    SyscallDenied(_) -> should.fail()
    SyscallFailed(_) -> should.fail()
  }
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

pub fn get_budget_registered_ok_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result = actor.invoke(gw, "agent_1", GetBudget)
  case result {
    SyscallOk(data) -> data |> should.equal("budget:agent=agent_1")
    SyscallDenied(_) -> should.fail()
    SyscallFailed(_) -> should.fail()
  }
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

pub fn emit_event_registered_ok_test() {
  let assert Ok(gw) = actor.start()
  actor.register_agent(gw, "agent_1")
  let result =
    actor.invoke(gw, "agent_1", EmitEvent("task_complete", "{\"id\":1}"))
  case result {
    SyscallOk(data) -> {
      data |> should.equal("event_emitted:task_complete:{\"id\":1}")
    }
    SyscallDenied(_) -> should.fail()
    SyscallFailed(_) -> should.fail()
  }
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
