//// Tests for the Kernel Scheduler Actor module
////
//// Integration tests — with actors, with I/O.

import gleam/erlang/process
import gleeunit
import gleeunit/should
import supernova/core/kernel_scheduler/actor
import supernova/core/kernel_scheduler/types.{High, Normal}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Actor Lifecycle Tests
// ============================================================================

pub fn start_and_stop_test() {
  let assert Ok(scheduler) = actor.start()
  actor.stop(scheduler)
  process.sleep(100)
}

// ============================================================================
// register Tests
// ============================================================================

pub fn register_success_test() {
  let assert Ok(scheduler) = actor.start()

  let subject = process.new_subject()
  let assert Ok(_) = actor.register(scheduler, "agent_1", subject, Normal, 10)

  let infos = actor.status(scheduler)
  infos
  |> should.not_equal([])

  actor.stop(scheduler)
  process.sleep(100)
}

pub fn register_duplicate_fails_test() {
  let assert Ok(scheduler) = actor.start()

  let subject = process.new_subject()
  let assert Ok(_) = actor.register(scheduler, "agent_1", subject, Normal, 10)

  let subject2 = process.new_subject()
  actor.register(scheduler, "agent_1", subject2, Normal, 10)
  |> should.be_error()

  actor.stop(scheduler)
  process.sleep(100)
}

// ============================================================================
// unregister Tests
// ============================================================================

pub fn unregister_success_test() {
  let assert Ok(scheduler) = actor.start()

  let subject = process.new_subject()
  let assert Ok(_) = actor.register(scheduler, "agent_1", subject, Normal, 10)
  let assert Ok(_) = actor.unregister(scheduler, "agent_1")

  let infos = actor.status(scheduler)
  infos
  |> should.equal([])

  actor.stop(scheduler)
  process.sleep(100)
}

pub fn unregister_not_found_fails_test() {
  let assert Ok(scheduler) = actor.start()

  actor.unregister(scheduler, "nonexistent")
  |> should.be_error()

  actor.stop(scheduler)
  process.sleep(100)
}

pub fn unregister_graceful_leaves_others_test() {
  let assert Ok(scheduler) = actor.start()

  let s1 = process.new_subject()
  let s2 = process.new_subject()
  let s3 = process.new_subject()
  let assert Ok(_) = actor.register(scheduler, "agent_1", s1, Normal, 10)
  let assert Ok(_) = actor.register(scheduler, "agent_2", s2, Normal, 10)
  let assert Ok(_) = actor.register(scheduler, "agent_3", s3, Normal, 10)

  let assert Ok(_) = actor.unregister(scheduler, "agent_2")

  let infos = actor.status(scheduler)
  infos
  |> should.not_equal([])

  actor.stop(scheduler)
  process.sleep(100)
}

// ============================================================================
// set_priority Tests
// ============================================================================

pub fn set_priority_success_test() {
  let assert Ok(scheduler) = actor.start()

  let subject = process.new_subject()
  let assert Ok(_) = actor.register(scheduler, "agent_1", subject, Normal, 10)
  let assert Ok(_) = actor.set_priority(scheduler, "agent_1", High)

  actor.stop(scheduler)
  process.sleep(100)
}

pub fn set_priority_not_found_fails_test() {
  let assert Ok(scheduler) = actor.start()

  actor.set_priority(scheduler, "nonexistent", High)
  |> should.be_error()

  actor.stop(scheduler)
  process.sleep(100)
}

// ============================================================================
// tick (fairness) Tests
// ============================================================================

pub fn tick_selects_agent_test() {
  let assert Ok(scheduler) = actor.start()

  let subject = process.new_subject()
  let assert Ok(_) = actor.register(scheduler, "agent_1", subject, Normal, 10)

  let result = actor.tick(scheduler)
  result
  |> should.be_ok()

  actor.stop(scheduler)
  process.sleep(100)
}

pub fn tick_empty_returns_error_test() {
  let assert Ok(scheduler) = actor.start()

  actor.tick(scheduler)
  |> should.be_error()

  actor.stop(scheduler)
  process.sleep(100)
}

pub fn tick_sends_message_to_agent_test() {
  let assert Ok(scheduler) = actor.start()

  // Create a subject we can receive on
  let subject: process.Subject(Nil) = process.new_subject()
  let assert Ok(_) = actor.register(scheduler, "agent_1", subject, Normal, 10)

  let assert Ok(_) = actor.tick(scheduler)

  // The agent's subject should have received a Nil message
  let result = process.receive(subject, 500)
  result
  |> should.be_ok()

  actor.stop(scheduler)
  process.sleep(100)
}

// ============================================================================
// detect_starved Tests
// ============================================================================

pub fn detect_starved_returns_count_test() {
  let assert Ok(scheduler) = actor.start()

  let subject = process.new_subject()
  let assert Ok(_) = actor.register(scheduler, "agent_1", subject, Normal, 10)

  // Agent has never run, should be starved
  let count = actor.detect_starved(scheduler)
  count
  |> should.equal(1)

  actor.stop(scheduler)
  process.sleep(100)
}

// ============================================================================
// reset_budgets Tests
// ============================================================================

pub fn reset_budgets_test() {
  let assert Ok(scheduler) = actor.start()

  let s1 = process.new_subject()
  let s2 = process.new_subject()
  let assert Ok(_) = actor.register(scheduler, "agent_1", s1, Normal, 1)
  let assert Ok(_) = actor.register(scheduler, "agent_2", s2, Normal, 1)

  // Exhaust both agents
  let _ = actor.tick(scheduler)
  let _ = actor.tick(scheduler)

  // Next tick should fail (all budgets at 0)
  actor.tick(scheduler)
  |> should.be_error()

  // Reset budgets
  actor.reset_budgets(scheduler, 10)

  // Now tick should succeed
  actor.tick(scheduler)
  |> should.be_ok()

  actor.stop(scheduler)
  process.sleep(100)
}
