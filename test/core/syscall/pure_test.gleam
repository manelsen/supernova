//// Syscall — Pure Tests
////
//// Tests for authentication, registration, dispatch, and count tracking.

import gleeunit/should
import supernova/core/syscall/pure
import supernova/core/syscall/types.{
  AuditDenied, CancelSchedule, EmitEvent, GetBudget, KillAgent, ReadFile,
  ReadWorld, RecordAudit, Schedule, SpawnAgent, WriteFile, WriteWorld,
  initial_state,
}

// ============================================================================
// Registration
// ============================================================================

pub fn register_adds_agent_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  pure.is_registered(state, "agent_1")
  |> should.be_true
}

pub fn unregistered_agent_not_found_test() {
  let state = initial_state()
  pure.is_registered(state, "agent_unknown")
  |> should.be_false
}

pub fn unregister_removes_agent_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  let state = pure.unregister(state, "agent_1")
  pure.is_registered(state, "agent_1")
  |> should.be_false
}

pub fn register_multiple_agents_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  let state = pure.register(state, "agent_2")
  pure.is_registered(state, "agent_1") |> should.be_true
  pure.is_registered(state, "agent_2") |> should.be_true
}

// ============================================================================
// Authentication
// ============================================================================

pub fn authenticate_registered_agent_ok_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  pure.authenticate(state, "agent_1")
  |> should.be_ok
}

pub fn authenticate_unregistered_agent_error_test() {
  let state = initial_state()
  pure.authenticate(state, "agent_ghost")
  |> should.be_error
}

// ============================================================================
// Dispatch — happy paths (authentication passes)
// ============================================================================

pub fn dispatch_read_file_registered_ok_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  let #(_, result, commands) =
    pure.dispatch(state, "agent_1", ReadFile("src/main.gleam"), 1000)
  result |> should.be_ok
  commands |> should.equal([])
}

pub fn dispatch_write_file_registered_ok_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  let #(_, result, _) =
    pure.dispatch(state, "agent_1", WriteFile("out.txt", "hello"), 1000)
  result |> should.be_ok
}

pub fn dispatch_spawn_agent_ok_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  let #(_, result, _) =
    pure.dispatch(state, "agent_1", SpawnAgent("{\"type\":\"worker\"}"), 1000)
  result |> should.be_ok
}

pub fn dispatch_kill_agent_ok_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  let #(_, result, _) =
    pure.dispatch(state, "agent_1", KillAgent("agent_2"), 1000)
  result |> should.be_ok
}

pub fn dispatch_read_world_ok_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  let #(_, result, _) = pure.dispatch(state, "agent_1", ReadWorld("sky"), 1000)
  result |> should.be_ok
}

pub fn dispatch_write_world_ok_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  let #(_, result, _) =
    pure.dispatch(state, "agent_1", WriteWorld("sky is blue", 0.9), 1000)
  result |> should.be_ok
}

pub fn dispatch_schedule_ok_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  let #(_, result, _) =
    pure.dispatch(state, "agent_1", Schedule("task_42", 5000), 1000)
  result |> should.be_ok
}

pub fn dispatch_cancel_schedule_ok_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  let #(_, result, _) =
    pure.dispatch(state, "agent_1", CancelSchedule("task_42"), 1000)
  result |> should.be_ok
}

pub fn dispatch_get_budget_ok_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  let #(_, result, _) = pure.dispatch(state, "agent_1", GetBudget, 1000)
  result |> should.be_ok
}

pub fn dispatch_emit_event_ok_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  let #(_, result, _) =
    pure.dispatch(
      state,
      "agent_1",
      EmitEvent("task_complete", "{\"id\":1}"),
      1000,
    )
  result |> should.be_ok
}

// ============================================================================
// Dispatch — denial paths (authentication fails)
// ============================================================================

pub fn dispatch_read_file_unregistered_denied_test() {
  let state = initial_state()
  let #(_, result, commands) =
    pure.dispatch(state, "agent_ghost", ReadFile("src/main.gleam"), 1000)
  result |> should.be_error
  commands |> should.not_equal([])
}

pub fn dispatch_write_file_unregistered_denied_test() {
  let state = initial_state()
  let #(_, result, _) =
    pure.dispatch(state, "agent_ghost", WriteFile("out.txt", "data"), 1000)
  result |> should.be_error
}

pub fn dispatch_spawn_agent_unregistered_denied_test() {
  let state = initial_state()
  let #(_, result, _) =
    pure.dispatch(state, "agent_ghost", SpawnAgent("{}"), 1000)
  result |> should.be_error
}

pub fn dispatch_kill_agent_unregistered_denied_test() {
  let state = initial_state()
  let #(_, result, _) =
    pure.dispatch(state, "agent_ghost", KillAgent("target"), 1000)
  result |> should.be_error
}

pub fn dispatch_read_world_unregistered_denied_test() {
  let state = initial_state()
  let #(_, result, _) =
    pure.dispatch(state, "agent_ghost", ReadWorld("facts"), 1000)
  result |> should.be_error
}

pub fn dispatch_write_world_unregistered_denied_test() {
  let state = initial_state()
  let #(_, result, _) =
    pure.dispatch(state, "agent_ghost", WriteWorld("content", 0.5), 1000)
  result |> should.be_error
}

pub fn dispatch_schedule_unregistered_denied_test() {
  let state = initial_state()
  let #(_, result, _) =
    pure.dispatch(state, "agent_ghost", Schedule("task_1", 1000), 1000)
  result |> should.be_error
}

pub fn dispatch_cancel_schedule_unregistered_denied_test() {
  let state = initial_state()
  let #(_, result, _) =
    pure.dispatch(state, "agent_ghost", CancelSchedule("task_1"), 1000)
  result |> should.be_error
}

pub fn dispatch_get_budget_unregistered_denied_test() {
  let state = initial_state()
  let #(_, result, _) = pure.dispatch(state, "agent_ghost", GetBudget, 1000)
  result |> should.be_error
}

pub fn dispatch_emit_event_unregistered_denied_test() {
  let state = initial_state()
  let #(_, result, _) =
    pure.dispatch(state, "agent_ghost", EmitEvent("ev", "{}"), 1000)
  result |> should.be_error
}

// ============================================================================
// Audit command content
// ============================================================================

pub fn dispatch_denied_produces_audit_command_test() {
  let state = initial_state()
  let #(_, _, commands) =
    pure.dispatch(state, "agent_ghost", ReadFile("secret.txt"), 999)
  let assert [
    RecordAudit(agent_id, operation, target, result_type, _details, timestamp),
  ] = commands
  agent_id |> should.equal("agent_ghost")
  operation |> should.equal("read_file")
  target |> should.equal("secret.txt")
  result_type |> should.equal(AuditDenied)
  timestamp |> should.equal(999)
}

// ============================================================================
// Count tracking
// ============================================================================

pub fn dispatch_increments_count_test() {
  let state = initial_state()
  let state = pure.register(state, "agent_1")
  let #(state, _, _) = pure.dispatch(state, "agent_1", GetBudget, 1000)
  let #(state, _, _) = pure.dispatch(state, "agent_1", GetBudget, 1001)
  pure.get_count(state, "agent_1") |> should.equal(2)
}

pub fn dispatch_denied_also_increments_count_test() {
  let state = initial_state()
  let #(state, _, _) = pure.dispatch(state, "agent_ghost", GetBudget, 1000)
  pure.get_count(state, "agent_ghost") |> should.equal(1)
}

pub fn get_count_unknown_agent_zero_test() {
  let state = initial_state()
  pure.get_count(state, "nobody") |> should.equal(0)
}
