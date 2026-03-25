//// Tests for Project Orchestrator — Actor Integration
////
//// Integration tests for the OTP actor: lifecycle, graph execution,
//// task completion, failure and phase transitions.

import gleam/dynamic
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should
import supernova/core/blackboard
import supernova/core/project/actor as orchestrator
import supernova/core/project/types
import supernova/core/sub_agent
import supernova/core/task_graph

// ============================================================================
// Helpers
// ============================================================================

fn success_result(task_id: String) -> sub_agent.SubAgentResult {
  sub_agent.SubAgentResult(
    agent_id: task_id <> "-agent",
    status: sub_agent.ResultSuccess,
    output: dynamic.string("done"),
    artifacts: [],
    tokens_used: 10,
    duration_ms: 100,
  )
}

fn failure_result(task_id: String, reason: String) -> sub_agent.SubAgentResult {
  sub_agent.SubAgentResult(
    agent_id: task_id <> "-agent",
    status: sub_agent.ResultFailure,
    output: dynamic.string(reason),
    artifacts: [],
    tokens_used: 5,
    duration_ms: 50,
  )
}

// ============================================================================
// Lifecycle
// ============================================================================

pub fn lifecycle_start_stop_test() {
  let config = types.default_config("proj_001")
  let assert Ok(orch) = orchestrator.start(config, None)

  orchestrator.stop(orch)
}

pub fn initial_phase_is_idle_test() {
  let config = types.default_config("proj_001")
  let assert Ok(orch) = orchestrator.start(config, None)

  orchestrator.get_phase(orch)
  |> should.equal(types.OrchestratorIdle)

  orchestrator.stop(orch)
  process.sleep(10)
}

// ============================================================================
// Graph Execution
// ============================================================================

pub fn empty_graph_is_immediately_done_test() {
  let config = types.default_config("proj_001")
  let assert Ok(orch) = orchestrator.start(config, None)

  let assert Ok(Nil) = orchestrator.start_graph(orch, task_graph.new())

  orchestrator.get_phase(orch)
  |> should.equal(types.OrchestratorDone)

  orchestrator.stop(orch)
  process.sleep(10)
}

pub fn single_task_graph_phase_is_running_test() {
  let config = types.default_config("proj_001")
  let assert Ok(orch) = orchestrator.start(config, None)

  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])

  let assert Ok(Nil) = orchestrator.start_graph(orch, graph)

  orchestrator.get_phase(orch)
  |> should.equal(types.OrchestratorRunning)

  orchestrator.stop(orch)
  process.sleep(10)
}

pub fn completing_all_tasks_transitions_to_done_test() {
  let config = types.default_config("proj_001")
  let assert Ok(orch) = orchestrator.start(config, None)

  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])

  let assert Ok(Nil) = orchestrator.start_graph(orch, graph)

  orchestrator.task_completed(orch, "a", success_result("a"))
  orchestrator.task_completed(orch, "b", success_result("b"))

  orchestrator.get_phase(orch)
  |> should.equal(types.OrchestratorDone)

  orchestrator.stop(orch)
  process.sleep(10)
}

pub fn parallel_tasks_complete_independently_test() {
  let config = types.default_config("proj_001")
  let assert Ok(orch) = orchestrator.start(config, None)

  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", [])
    |> task_graph.add_task("c", "Task C", [])

  let assert Ok(Nil) = orchestrator.start_graph(orch, graph)

  // Complete in non-alphabetical order
  orchestrator.task_completed(orch, "c", success_result("c"))
  orchestrator.task_completed(orch, "a", success_result("a"))
  orchestrator.task_completed(orch, "b", success_result("b"))

  orchestrator.get_phase(orch)
  |> should.equal(types.OrchestratorDone)

  orchestrator.stop(orch)
  process.sleep(10)
}

// ============================================================================
// Failure via ResultFailure in TaskCompleted
// ============================================================================

pub fn task_failure_via_result_transitions_to_failed_phase_test() {
  let config = types.default_config("proj_001")
  let assert Ok(orch) = orchestrator.start(config, None)

  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])

  let assert Ok(Nil) = orchestrator.start_graph(orch, graph)
  // Pass a ResultFailure result — orchestrator should cascade to Failed phase
  orchestrator.task_completed(orch, "a", failure_result("a", "crash"))

  let phase = orchestrator.get_phase(orch)
  case phase {
    types.OrchestratorFailed(_) -> Nil
    _ -> should.fail()
  }

  orchestrator.stop(orch)
  process.sleep(10)
}

// ============================================================================
// Failure via task_failed (existing API)
// ============================================================================

pub fn task_failure_transitions_to_failed_phase_test() {
  let config = types.default_config("proj_001")
  let assert Ok(orch) = orchestrator.start(config, None)

  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])

  let assert Ok(Nil) = orchestrator.start_graph(orch, graph)
  orchestrator.task_failed(orch, "a", "crash")

  let phase = orchestrator.get_phase(orch)
  case phase {
    types.OrchestratorFailed(_) -> Nil
    _ -> should.fail()
  }

  orchestrator.stop(orch)
  process.sleep(10)
}

pub fn failure_with_cascade_remains_failed_phase_test() {
  let config = types.default_config("proj_001")
  let assert Ok(orch) = orchestrator.start(config, None)

  // a → b → c; a fails → b,c cancelled
  let graph =
    task_graph.new()
    |> task_graph.add_task("a", "Task A", [])
    |> task_graph.add_task("b", "Task B", ["a"])
    |> task_graph.add_task("c", "Task C", ["b"])

  let assert Ok(Nil) = orchestrator.start_graph(orch, graph)
  orchestrator.task_failed(orch, "a", "error")

  let phase = orchestrator.get_phase(orch)
  case phase {
    types.OrchestratorFailed(_) -> Nil
    _ -> should.fail()
  }

  orchestrator.stop(orch)
  process.sleep(10)
}

// ============================================================================
// Blackboard Integration
// ============================================================================

pub fn progress_reported_to_blackboard_test() {
  let assert Ok(bb) = blackboard.start()
  let config = types.default_config("proj_001")
  let assert Ok(orch) = orchestrator.start(config, Some(bb))

  let graph =
    task_graph.new()
    |> task_graph.add_task("task1", "Task 1", [])

  let assert Ok(Nil) = orchestrator.start_graph(orch, graph)

  // "task1" should be reported as running in the blackboard
  let entry = blackboard.get(bb, "task:task1")
  case entry {
    Some(e) ->
      e.value
      |> should.equal("running")
    None -> should.fail()
  }

  orchestrator.task_completed(orch, "task1", success_result("task1"))

  let entry2 = blackboard.get(bb, "task:task1")
  case entry2 {
    Some(e) ->
      e.value
      |> should.equal("done")
    None -> should.fail()
  }

  orchestrator.stop(orch)
  blackboard.stop(bb)
  process.sleep(10)
}
