//// Tests for the Kernel Scheduler Pure module
////
//// Pure tests — no I/O, no actors, no FFI.

import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/kernel_scheduler/pure
import supernova/core/kernel_scheduler/types.{
  Critical, High, Idle, Low, Normal, Starved,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helper: fake Subject
// ============================================================================

// We can't easily create a real Subject(Nil) in pure tests,
// so we use a process self subject as a stand-in.

import gleam/erlang/process

fn make_subject() -> process.Subject(Nil) {
  process.new_subject()
}

fn empty_state() -> types.KernelSchedulerState {
  types.initial_state()
}

fn register_agent(
  state: types.KernelSchedulerState,
  id: String,
) -> types.KernelSchedulerState {
  let subject = make_subject()
  let opts = types.SchedulerOpts(subject: subject, priority: Normal, budget: 10)
  let #(new_state, _) = pure.register(state, id, opts)
  new_state
}

fn register_agent_with(
  state: types.KernelSchedulerState,
  id: String,
  priority: types.SchedulerPriority,
  budget: Int,
) -> types.KernelSchedulerState {
  let subject = make_subject()
  let opts =
    types.SchedulerOpts(subject: subject, priority: priority, budget: budget)
  let #(new_state, _) = pure.register(state, id, opts)
  new_state
}

// ============================================================================
// register Tests
// ============================================================================

pub fn register_success_test() {
  let state = empty_state()
  let subject = make_subject()
  let opts = types.SchedulerOpts(subject: subject, priority: Normal, budget: 10)
  let #(new_state, result) = pure.register(state, "agent_1", opts)

  result
  |> should.be_ok()

  pure.status(new_state)
  |> list.length()
  |> should.equal(1)
}

pub fn register_duplicate_fails_test() {
  let state = empty_state()
  let state1 = register_agent(state, "agent_1")

  let subject = make_subject()
  let opts = types.SchedulerOpts(subject: subject, priority: Normal, budget: 10)
  let #(_, result) = pure.register(state1, "agent_1", opts)

  result
  |> should.be_error()
}

pub fn register_initial_status_idle_test() {
  let state = empty_state()
  let state1 = register_agent(state, "agent_1")

  let infos = pure.status(state1)
  let assert [info] = infos

  info.status
  |> should.equal(Idle)
}

// ============================================================================
// unregister Tests
// ============================================================================

pub fn unregister_success_test() {
  let state = empty_state()
  let state1 = register_agent(state, "agent_1")

  let #(new_state, result) = pure.unregister(state1, "agent_1")

  result
  |> should.be_ok()

  pure.status(new_state)
  |> list.length()
  |> should.equal(0)
}

pub fn unregister_not_found_fails_test() {
  let state = empty_state()
  let #(_, result) = pure.unregister(state, "nonexistent")

  result
  |> should.be_error()
}

pub fn unregister_graceful_multiple_agents_test() {
  let state = empty_state()
  let state1 = register_agent(state, "agent_1")
  let state2 = register_agent(state1, "agent_2")
  let state3 = register_agent(state2, "agent_3")

  let #(new_state, _) = pure.unregister(state3, "agent_2")

  pure.status(new_state)
  |> list.length()
  |> should.equal(2)
}

// ============================================================================
// set_priority Tests
// ============================================================================

pub fn set_priority_success_test() {
  let state = empty_state()
  let state1 = register_agent(state, "agent_1")

  let #(new_state, result) = pure.set_priority(state1, "agent_1", High)

  result
  |> should.be_ok()

  let infos = pure.status(new_state)
  let assert [info] = infos

  info.priority
  |> should.equal(High)
}

pub fn set_priority_not_found_fails_test() {
  let state = empty_state()
  let #(_, result) = pure.set_priority(state, "nonexistent", High)

  result
  |> should.be_error()
}

// ============================================================================
// status Tests
// ============================================================================

pub fn status_empty_test() {
  let state = empty_state()

  pure.status(state)
  |> list.length()
  |> should.equal(0)
}

pub fn status_multiple_agents_test() {
  let state = empty_state()
  let state1 = register_agent(state, "agent_1")
  let state2 = register_agent(state1, "agent_2")
  let state3 = register_agent(state2, "agent_3")

  pure.status(state3)
  |> list.length()
  |> should.equal(3)
}

// ============================================================================
// next_agent (fairness) Tests
// ============================================================================

pub fn next_agent_returns_agent_test() {
  let state = empty_state()
  let state1 = register_agent(state, "agent_1")

  let #(_, result) = pure.next_agent(state1, 1000)

  result
  |> should.be_ok()
}

pub fn next_agent_empty_returns_error_test() {
  let state = empty_state()
  let #(_, result) = pure.next_agent(state, 1000)

  result
  |> should.be_error()
}

pub fn next_agent_budget_zero_skipped_test() {
  let state = empty_state()
  let state1 = register_agent_with(state, "agent_1", Normal, 0)
  let state2 = register_agent_with(state1, "agent_2", Normal, 10)

  let #(_, result) = pure.next_agent(state2, 1000)

  case result {
    Ok(info) ->
      info.agent_id
      |> should.equal("agent_2")
    Error(_) -> should.fail()
  }
}

pub fn next_agent_all_budget_zero_returns_error_test() {
  let state = empty_state()
  let state1 = register_agent_with(state, "agent_1", Normal, 0)
  let state2 = register_agent_with(state1, "agent_2", Normal, 0)

  let #(_, result) = pure.next_agent(state2, 1000)

  result
  |> should.be_error()
}

pub fn next_agent_higher_priority_selected_first_test() {
  let state = empty_state()
  let state1 = register_agent_with(state, "low_agent", Low, 10)
  let state2 = register_agent_with(state1, "high_agent", Critical, 10)

  let #(_, result) = pure.next_agent(state2, 1000)

  case result {
    Ok(info) ->
      info.agent_id
      |> should.equal("high_agent")
    Error(_) -> should.fail()
  }
}

pub fn next_agent_decrement_budget_test() {
  let state = empty_state()
  let state1 = register_agent_with(state, "agent_1", Normal, 5)

  let assert #(new_state, Ok(info)) = pure.next_agent(state1, 1000)

  info.agent_id
  |> should.equal("agent_1")

  // After tick, check budget in new state via status
  let infos = pure.status(new_state)
  let assert [updated] = infos
  updated.budget_remaining
  |> should.equal(4)
}

pub fn next_agent_unlimited_budget_unchanged_test() {
  let state = empty_state()
  let state1 = register_agent_with(state, "agent_1", Normal, -1)

  let assert #(new_state, Ok(_)) = pure.next_agent(state1, 1000)

  let infos = pure.status(new_state)
  let assert [updated] = infos
  updated.budget_remaining
  |> should.equal(-1)
}

// ============================================================================
// detect_starved Tests (starvation prevention)
// ============================================================================

pub fn detect_starved_never_run_test() {
  let state = empty_state()
  let state1 = register_agent(state, "agent_1")

  // last_run = 0 means never run — should be starved
  let now = 60_000
  let #(new_state, commands) = pure.detect_starved(state1, now)

  list.length(commands)
  |> should.equal(1)

  let infos = pure.status(new_state)
  let assert [info] = infos
  info.status
  |> should.equal(Starved)
}

pub fn detect_starved_recently_run_not_starved_test() {
  let state = empty_state()
  let state1 = register_agent(state, "agent_1")

  // First tick at t=1000 so last_run = 1000
  let #(state2, _) = pure.next_agent(state1, 1000)

  // Check at t=5000 (4 seconds later, below 30s threshold)
  let #(_, commands) = pure.detect_starved(state2, 5000)

  list.length(commands)
  |> should.equal(0)
}

pub fn detect_starved_elevates_priority_test() {
  let state = empty_state()
  let state1 = register_agent_with(state, "agent_1", Low, 10)

  // Never run — starvation detected
  let now = 60_000
  let #(new_state, commands) = pure.detect_starved(state1, now)

  list.length(commands)
  |> should.equal(1)

  let infos = pure.status(new_state)
  let assert [info] = infos
  // Low should boost to Normal
  info.priority
  |> should.equal(Normal)
}

pub fn detect_starved_budget_zero_not_starved_test() {
  let state = empty_state()
  // Agent with zero budget — should NOT be considered starved
  let state1 = register_agent_with(state, "agent_1", Normal, 0)

  let now = 60_000
  let #(_, commands) = pure.detect_starved(state1, now)

  list.length(commands)
  |> should.equal(0)
}

// ============================================================================
// reset_budgets Tests
// ============================================================================

pub fn reset_budgets_restores_all_test() {
  let state = empty_state()
  let state1 = register_agent_with(state, "agent_1", Normal, 5)
  let state2 = register_agent_with(state1, "agent_2", Normal, 5)

  // Exhaust both budgets
  let #(state3, _) = pure.next_agent(state2, 1000)
  let #(state4, _) = pure.next_agent(state3, 1000)
  let #(state5, _) = pure.next_agent(state4, 1000)
  let #(state6, _) = pure.next_agent(state5, 1000)
  let #(state7, _) = pure.next_agent(state6, 1000)

  // Reset budgets to 10
  let new_state = pure.reset_budgets(state7, 10)

  let infos = pure.status(new_state)
  list.each(infos, fn(info) {
    info.budget_remaining
    |> should.equal(10)
  })
}
