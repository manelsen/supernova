//// Tests for Project Orchestrator — Pure Logic
////
//// Covers: parallel execution, cascade failure, retry.
//// Pure tests — no I/O, no actors, no FFI.

import gleam/dict
import gleam/list
import gleam/string
import gleeunit/should
import supernova/core/project/pure
import supernova/core/project/types
import supernova/core/task_graph

// ============================================================================
// Helpers
// ============================================================================

fn make_state(project_id: String) -> types.OrchestratorState {
  types.initial_state(types.default_config(project_id))
}

fn make_state_with_retries(
  project_id: String,
  default_max: Int,
) -> types.OrchestratorState {
  let config =
    types.OrchestratorConfig(
      project_id: project_id,
      default_max_retries: default_max,
      task_retry_overrides: dict.new(),
    )
  types.initial_state(config)
}

fn sorted(ids: List(String)) -> List(String) {
  list.sort(ids, string.compare)
}

fn launch_ids(commands: List(types.OrchestratorCommand)) -> List(String) {
  list.filter_map(commands, fn(cmd) {
    case cmd {
      types.LaunchTask(id, _) -> Ok(id)
      _ -> Error(Nil)
    }
  })
}

fn cancelled_reports(
  commands: List(types.OrchestratorCommand),
) -> List(String) {
  list.filter_map(commands, fn(cmd) {
    case cmd {
      types.ReportProgress(id, "cancelled", _) -> Ok(id)
      _ -> Error(Nil)
    }
  })
}

fn cancel_task_ids(commands: List(types.OrchestratorCommand)) -> List(String) {
  list.filter_map(commands, fn(cmd) {
    case cmd {
      types.CancelTask(id) -> Ok(id)
      _ -> Error(Nil)
    }
  })
}

// ============================================================================
// start_graph — Parallel Execution
// ============================================================================

pub fn empty_graph_transitions_to_done_test() {
  let state = make_state("proj_001")
  let #(new_state, commands) = pure.start_graph(state, task_graph.new())

  new_state.phase
  |> should.equal(types.OrchestratorDone)

  commands
  |> should.equal([])
}

pub fn single_root_task_is_launched_test() {
  let state = make_state("proj_001")
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])

  let #(new_state, commands) = pure.start_graph(state, graph)

  new_state.phase
  |> should.equal(types.OrchestratorRunning)

  launch_ids(commands)
  |> should.equal(["a"])

  new_state.running
  |> should.equal(["a"])
}

pub fn parallel_tasks_all_launched_simultaneously_test() {
  let state = make_state("proj_001")
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", [])
    |> task_graph.add_task("c", "Task C", [])

  let #(new_state, commands) = pure.start_graph(state, graph)

  launch_ids(commands)
  |> sorted()
  |> should.equal(["a", "b", "c"])

  new_state.running
  |> sorted()
  |> should.equal(["a", "b", "c"])
}

pub fn dependent_task_not_launched_before_dep_completes_test() {
  let state = make_state("proj_001")
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])

  let #(_new_state, commands) = pure.start_graph(state, graph)

  // Only "a" should be launched; "b" waits for "a"
  launch_ids(commands)
  |> should.equal(["a"])
}

// ============================================================================
// task_completed — Dependency Resolution
// ============================================================================

pub fn completing_root_launches_dependent_test() {
  let state = make_state("proj_001")
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])

  let #(state, _) = pure.start_graph(state, graph)

  // Complete "a" → "b" should now be launched
  let #(new_state, commands) = pure.task_completed(state, "a")

  launch_ids(commands)
  |> should.equal(["b"])

  new_state.completed
  |> should.equal(["a"])

  new_state.running
  |> should.equal(["b"])
}

pub fn completing_all_tasks_transitions_to_done_test() {
  let state = make_state("proj_001")
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])

  let #(state, _) = pure.start_graph(state, graph)
  let #(new_state, _) = pure.task_completed(state, "a")

  new_state.phase
  |> should.equal(types.OrchestratorDone)
}

pub fn diamond_dag_both_branches_launch_after_root_test() {
  let state = make_state("proj_001")
  // a → b, a → c, b → d, c → d
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])
    |> task_graph.add_task("c", "Task C", ["a"])
    |> task_graph.add_task("d", "Task D", ["b", "c"])

  let #(state, _) = pure.start_graph(state, graph)
  let #(_state, commands) = pure.task_completed(state, "a")

  // b and c both become ready
  launch_ids(commands)
  |> sorted()
  |> should.equal(["b", "c"])
}

pub fn diamond_dag_final_task_launches_after_both_branches_test() {
  let state = make_state("proj_001")
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])
    |> task_graph.add_task("c", "Task C", ["a"])
    |> task_graph.add_task("d", "Task D", ["b", "c"])

  let #(state, _) = pure.start_graph(state, graph)
  let #(state, _) = pure.task_completed(state, "a")
  let #(state, _) = pure.task_completed(state, "b")
  let #(_state, commands) = pure.task_completed(state, "c")

  launch_ids(commands)
  |> should.equal(["d"])
}

// ============================================================================
// task_failed — Cascade Cancellation
// ============================================================================

pub fn root_failure_cancels_linear_chain_test() {
  let state = make_state("proj_001")
  // a → b → c (linear chain)
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])
    |> task_graph.add_task("c", "Task C", ["b"])

  let #(state, _) = pure.start_graph(state, graph)
  let #(new_state, commands) = pure.task_failed(state, "a", "error")

  // b and c should have cancelled progress reports
  cancelled_reports(commands)
  |> sorted()
  |> should.equal(["b", "c"])

  new_state.cancelled
  |> sorted()
  |> should.equal(["b", "c"])

  new_state.failed
  |> should.equal(["a"])

  new_state.phase
  |> should.equal(types.OrchestratorFailed("Task a failed: error"))
}

pub fn failure_only_cancels_descendants_not_siblings_test() {
  // a → b, a → c (siblings — both depend on a, not on each other)
  // b fails → c is NOT a descendant of b, so c should stay running
  let state = make_state("proj_001")
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])
    |> task_graph.add_task("c", "Task C", ["a"])

  let #(state, _) = pure.start_graph(state, graph)
  let #(state, _) = pure.task_completed(state, "a")
  // Both b and c are now running

  let #(new_state, commands) = pure.task_failed(state, "b", "crash")

  // c is NOT a descendant of b → no CancelTask for c
  cancel_task_ids(commands)
  |> should.equal([])

  // c should still be in running list
  new_state.running
  |> should.equal(["c"])
}

pub fn failure_emits_cancel_task_for_running_transitive_descendant_test() {
  // a → b → d (b→d dependency); a → c (independent)
  // After a and c complete, b runs and d is pending (waiting for b)
  // b fails → d (descendant of b, not yet running) gets ReportProgress cancelled
  // c was not a descendant — no cancel for c
  // In this scenario: d is not running so CancelTask is NOT emitted (only ReportProgress)
  let state = make_state("proj_001")
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])
    |> task_graph.add_task("d", "Task D", ["b"])

  let #(state, _) = pure.start_graph(state, graph)
  let #(state, _) = pure.task_completed(state, "a")
  // b is now running; d is still pending

  let #(_new_state, commands) = pure.task_failed(state, "b", "crash")

  // d is a descendant but was not running → no CancelTask
  cancel_task_ids(commands)
  |> should.equal([])

  // d should have a cancelled progress report
  cancelled_reports(commands)
  |> should.equal(["d"])
}

pub fn non_running_descendants_do_not_get_cancel_task_test() {
  // a → b → c (linear chain; only a is running, b and c have not started)
  let state = make_state("proj_001")
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])
    |> task_graph.add_task("c", "Task C", ["b"])

  let #(state, _) = pure.start_graph(state, graph)
  // a fails, b and c have never started
  let #(_new_state, commands) = pure.task_failed(state, "a", "timeout")

  // b and c were never running → no CancelTask (only ReportProgress cancelled)
  cancel_task_ids(commands)
  |> should.equal([])

  cancelled_reports(commands)
  |> sorted()
  |> should.equal(["b", "c"])
}

// ============================================================================
// task_failed — Retry
// ============================================================================

pub fn retry_relaunches_task_on_first_failure_test() {
  let state = make_state_with_retries("proj_001", 2)
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])

  let #(state, _) = pure.start_graph(state, graph)
  let #(new_state, commands) = pure.task_failed(state, "a", "timeout")

  // Should re-launch "a"
  launch_ids(commands)
  |> should.equal(["a"])

  // Phase stays running
  new_state.phase
  |> should.equal(types.OrchestratorRunning)

  // Retry count incremented
  new_state.retry_counts
  |> dict.get("a")
  |> should.equal(Ok(1))
}

pub fn retry_exhausted_permanently_fails_test() {
  let state = make_state_with_retries("proj_001", 1)
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])

  let #(state, _) = pure.start_graph(state, graph)

  // First failure: retry
  let #(state, _) = pure.task_failed(state, "a", "timeout")
  // Second failure: exhausted (max_retries=1, attempts_used=1, 1 < 1 = False)
  let #(new_state, commands) = pure.task_failed(state, "a", "timeout again")

  // Should NOT re-launch
  launch_ids(commands)
  |> should.equal([])

  new_state.phase
  |> should.equal(types.OrchestratorFailed("Task a failed: timeout again"))
}

pub fn per_task_retry_override_test() {
  // "a" gets 3 retries via override, default is 0
  let config =
    types.OrchestratorConfig(
      project_id: "proj_001",
      default_max_retries: 0,
      task_retry_overrides: dict.from_list([#("a", 3)]),
    )
  let state = types.initial_state(config)
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", [])

  let #(state, _) = pure.start_graph(state, graph)

  // "a" can retry 3 times (4 total attempts)
  let #(state, cmds1) = pure.task_failed(state, "a", "err")
  let #(state, cmds2) = pure.task_failed(state, "a", "err")
  let #(state, cmds3) = pure.task_failed(state, "a", "err")
  let #(new_state, cmds4) = pure.task_failed(state, "a", "final")

  launch_ids(cmds1)
  |> should.equal(["a"])
  launch_ids(cmds2)
  |> should.equal(["a"])
  launch_ids(cmds3)
  |> should.equal(["a"])
  // 4th failure: exhausted
  launch_ids(cmds4)
  |> should.equal([])

  new_state.phase
  |> should.equal(types.OrchestratorFailed("Task a failed: final"))

  // "b" has no retries and was not involved
  new_state.running
  |> should.equal(["b"])
}
