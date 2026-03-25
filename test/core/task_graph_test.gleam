//// Tests for TaskGraph — Directed Acyclic Graph of Tasks
////
//// Pure tests — no I/O, no actors, no FFI.

import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import supernova/core/task_graph

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helpers
// ============================================================================

fn sorted(ids: List(String)) -> List(String) {
  list.sort(ids, string.compare)
}

// ============================================================================
// new() Tests
// ============================================================================

pub fn new_returns_empty_graph_test() {
  let g = task_graph.new()
  task_graph.ready_tasks(g, [])
  |> should.equal([])
}

// ============================================================================
// add_task() Tests
// ============================================================================

pub fn add_task_no_deps_test() {
  let g =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])

  task_graph.ready_tasks(g, [])
  |> should.equal(["a"])
}

pub fn add_multiple_tasks_no_deps_test() {
  let g =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", [])
    |> task_graph.add_task("c", "Task C", [])

  task_graph.ready_tasks(g, [])
  |> sorted()
  |> should.equal(["a", "b", "c"])
}

// ============================================================================
// validate() — DAG Tests
// ============================================================================

pub fn validate_empty_graph_is_ok_test() {
  task_graph.new()
  |> task_graph.validate()
  |> should.be_ok()
}

pub fn validate_linear_dag_is_ok_test() {
  task_graph.new()
  |> task_graph.add_task("a", "Task A", [])
  |> task_graph.add_task("b", "Task B", ["a"])
  |> task_graph.add_task("c", "Task C", ["b"])
  |> task_graph.validate()
  |> should.be_ok()
}

pub fn validate_parallel_dag_is_ok_test() {
  // a and b are independent; c depends on both
  task_graph.new()
  |> task_graph.add_task("a", "Task A", [])
  |> task_graph.add_task("b", "Task B", [])
  |> task_graph.add_task("c", "Task C", ["a", "b"])
  |> task_graph.validate()
  |> should.be_ok()
}

pub fn validate_diamond_dag_is_ok_test() {
  // a -> b, a -> c, b -> d, c -> d
  task_graph.new()
  |> task_graph.add_task("a", "Task A", [])
  |> task_graph.add_task("b", "Task B", ["a"])
  |> task_graph.add_task("c", "Task C", ["a"])
  |> task_graph.add_task("d", "Task D", ["b", "c"])
  |> task_graph.validate()
  |> should.be_ok()
}

pub fn validate_direct_cycle_is_error_test() {
  // a -> b -> a
  let g =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", ["b"])
    |> task_graph.add_task("b", "Task B", ["a"])

  task_graph.validate(g)
  |> should.be_error()
}

pub fn validate_indirect_cycle_is_error_test() {
  // a -> b -> c -> a
  let g =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", ["c"])
    |> task_graph.add_task("b", "Task B", ["a"])
    |> task_graph.add_task("c", "Task C", ["b"])

  task_graph.validate(g)
  |> should.be_error()
}

pub fn validate_self_loop_is_error_test() {
  let g =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", ["a"])

  task_graph.validate(g)
  |> should.be_error()
}

pub fn validate_error_message_mentions_cycle_test() {
  let g =
    task_graph.new()
    |> task_graph.add_task("x", "Task X", ["x"])

  let assert Error(msg) = task_graph.validate(g)
  msg
  |> should.equal("Cycle detected involving task: x")
}

// ============================================================================
// ready_tasks() Tests
// ============================================================================

pub fn ready_tasks_empty_completed_returns_roots_test() {
  // Only tasks with no deps should be ready initially
  let g =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])
    |> task_graph.add_task("c", "Task C", ["a"])

  task_graph.ready_tasks(g, [])
  |> should.equal(["a"])
}

pub fn ready_tasks_after_completing_root_test() {
  let g =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])
    |> task_graph.add_task("c", "Task C", ["a"])

  task_graph.ready_tasks(g, ["a"])
  |> sorted()
  |> should.equal(["b", "c"])
}

pub fn ready_tasks_diamond_after_first_test() {
  let g =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])
    |> task_graph.add_task("c", "Task C", ["a"])
    |> task_graph.add_task("d", "Task D", ["b", "c"])

  // After a completes, b and c are ready; d is not yet
  task_graph.ready_tasks(g, ["a"])
  |> sorted()
  |> should.equal(["b", "c"])
}

pub fn ready_tasks_diamond_after_b_and_c_test() {
  let g =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])
    |> task_graph.add_task("c", "Task C", ["a"])
    |> task_graph.add_task("d", "Task D", ["b", "c"])

  task_graph.ready_tasks(g, ["a", "b", "c"])
  |> should.equal(["d"])
}

pub fn ready_tasks_excludes_done_tasks_test() {
  let g =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", [])
    |> task_graph.mark_done("a")

  // "a" is Done, not Pending — should not appear in ready
  task_graph.ready_tasks(g, [])
  |> should.equal(["b"])
}

// ============================================================================
// mark_done() / mark_failed() Tests
// ============================================================================

pub fn mark_done_changes_status_test() {
  let g =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.mark_done("a")

  // "a" should no longer appear in ready_tasks (it's Done, not Pending)
  task_graph.ready_tasks(g, [])
  |> should.equal([])
}

pub fn mark_failed_changes_status_test() {
  let g =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.mark_failed("a")

  task_graph.ready_tasks(g, [])
  |> should.equal([])
}

pub fn mark_done_nonexistent_is_noop_test() {
  let g = task_graph.new()
  task_graph.mark_done(g, "nonexistent")
  |> task_graph.ready_tasks([])
  |> should.equal([])
}

pub fn mark_failed_nonexistent_is_noop_test() {
  let g = task_graph.new()
  task_graph.mark_failed(g, "nonexistent")
  |> task_graph.ready_tasks([])
  |> should.equal([])
}

// ============================================================================
// Linear DAG Walkthrough
// ============================================================================

pub fn linear_dag_full_walkthrough_test() {
  let g =
    task_graph.new()
    |> task_graph.add_task("step1", "Step 1", [])
    |> task_graph.add_task("step2", "Step 2", ["step1"])
    |> task_graph.add_task("step3", "Step 3", ["step2"])

  // Initially only step1 is ready
  task_graph.ready_tasks(g, [])
  |> should.equal(["step1"])

  // After step1 done
  task_graph.ready_tasks(g, ["step1"])
  |> should.equal(["step2"])

  // After step2 done
  task_graph.ready_tasks(g, ["step1", "step2"])
  |> should.equal(["step3"])

  // After all done
  task_graph.ready_tasks(g, ["step1", "step2", "step3"])
  |> should.equal([])
}
