//// KernelAPI — Actor Tests
////
//// Tests for the kernel API actor.

import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit/should
import supernova/core/audit_log/actor as audit_actor
import supernova/core/kernel_api/actor
import supernova/core/kernel_api/types
import supernova/core/kernel_scheduler/actor as scheduler_actor
import supernova/core/kernel_scheduler/types as scheduler_types
import supernova/core/world_model/actor as world_actor
import supernova/core/world_model/types as world_model_types

// ============================================================================
// Setup Helpers
// ============================================================================

fn create_test_actors() {
  let assert Ok(scheduler) = scheduler_actor.start()
  let assert Ok(world_model) = world_actor.start()
  let assert Ok(audit_log) = audit_actor.start("test_workspace")
  let assert Ok(api) = actor.start(scheduler, world_model, audit_log)
  #(api, scheduler, world_model, audit_log)
}

fn cleanup_actors(api, scheduler, world_model, audit_log) -> Nil {
  actor.stop(api)
  scheduler_actor.stop(scheduler)
  world_actor.stop(world_model)
  audit_actor.stop(audit_log)
}

// ============================================================================
// Tool Definition Tests
// ============================================================================

pub fn kernel_status_tool_definition_test() {
  let tool = actor.kernel_status_tool()
  tool.name |> should.equal("kernel.status")
  tool.description |> string.contains("status") |> should.be_true
}

pub fn kernel_world_query_tool_definition_test() {
  let tool = actor.kernel_world_query_tool()
  tool.name |> should.equal("kernel.world_query")
  tool.description |> string.contains("world model") |> should.be_true
}

pub fn kernel_audit_recent_tool_definition_test() {
  let tool = actor.kernel_audit_recent_tool()
  tool.name |> should.equal("kernel.audit_recent")
  tool.description |> string.contains("audit") |> should.be_true
}

pub fn kernel_set_priority_tool_definition_test() {
  let tool = actor.kernel_set_priority_tool()
  tool.name |> should.equal("kernel.set_priority")
  tool.description |> string.contains("priority") |> should.be_true
}

pub fn all_tool_definitions_count_test() {
  let tools = actor.all_tool_definitions()
  tools |> list.length |> should.equal(4)
}

// ============================================================================
// Kernel Status Tests
// ============================================================================

pub fn kernel_status_empty_test() {
  let #(api, scheduler, world_model, audit_log) = create_test_actors()
  let result = actor.handle(api, "agent_1", types.Status)
  let assert types.KernelApiOk(data) = result
  data |> should.equal("[]")
  cleanup_actors(api, scheduler, world_model, audit_log)
}

pub fn kernel_status_with_agents_test() {
  let #(api, scheduler, world_model, audit_log) = create_test_actors()

  // Register some agents
  let subject = process.new_subject()
  let _ =
    scheduler_actor.register(
      scheduler,
      "agent_1",
      subject,
      scheduler_types.Normal,
      100,
    )
  let _ =
    scheduler_actor.register(
      scheduler,
      "agent_2",
      subject,
      scheduler_types.High,
      50,
    )

  let result = actor.handle(api, "agent_1", types.Status)
  let assert types.KernelApiOk(data) = result
  data |> string.contains("agent_1") |> should.be_true
  data |> string.contains("agent_2") |> should.be_true
  cleanup_actors(api, scheduler, world_model, audit_log)
}

// ============================================================================
// World Query Tests
// ============================================================================

pub fn world_query_empty_test() {
  let #(api, scheduler, world_model, audit_log) = create_test_actors()

  let result = actor.handle(api, "agent_1", types.WorldQuery(""))
  let assert types.KernelApiOk(data) = result
  data |> should.equal("[]")
  cleanup_actors(api, scheduler, world_model, audit_log)
}

pub fn world_query_with_facts_test() {
  let #(api, scheduler, world_model, audit_log) = create_test_actors()

  // Add some facts
  let _ =
    world_actor.assert_fact(
      world_model,
      "agent_1",
      "test fact",
      world_model_types.FactEntity,
      0.9,
    )
  let _ =
    world_actor.assert_fact(
      world_model,
      "agent_1",
      "another fact",
      world_model_types.FactDecision,
      0.8,
    )

  let result = actor.handle(api, "agent_1", types.WorldQuery("fact"))
  let assert types.KernelApiOk(data) = result
  // Should contain both facts since they contain "fact"
  data |> string.contains("test fact") |> should.be_true
  data |> string.contains("another fact") |> should.be_true
  cleanup_actors(api, scheduler, world_model, audit_log)
}

// ============================================================================
// Audit Recent Tests
// ============================================================================

pub fn audit_recent_empty_test() {
  let #(api, scheduler, world_model, audit_log) = create_test_actors()

  let result =
    actor.handle(api, "agent_1", types.AuditRecent("unknown_agent", 10))
  let assert types.KernelApiOk(data) = result
  data |> should.equal("[]")
  cleanup_actors(api, scheduler, world_model, audit_log)
}

// ============================================================================
// Set Priority Tests
// ============================================================================

pub fn set_priority_unknown_agent_test() {
  let #(api, scheduler, world_model, audit_log) = create_test_actors()

  let result =
    actor.handle(
      api,
      "agent_1",
      types.SetPriority("unknown_agent", scheduler_types.High),
    )
  let assert types.KernelApiError(_) = result
  cleanup_actors(api, scheduler, world_model, audit_log)
}

pub fn set_priority_with_existing_agent_test() {
  let #(api, scheduler, world_model, audit_log) = create_test_actors()

  // Register an agent first
  let subject = process.new_subject()
  let _ =
    scheduler_actor.register(
      scheduler,
      "agent_1",
      subject,
      scheduler_types.Normal,
      100,
    )

  // Try to set priority on the registered agent
  let result =
    actor.handle(
      api,
      "agent_1",
      types.SetPriority("agent_1", scheduler_types.High),
    )
  let assert types.KernelApiOk(data) = result
  data |> string.contains("priority_updated") |> should.be_true
  cleanup_actors(api, scheduler, world_model, audit_log)
}
