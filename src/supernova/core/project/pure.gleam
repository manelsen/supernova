//// Project Orchestrator — Pure Functions
////
//// Pure logic for TaskGraph-based orchestration. No FFI, no OTP imports.
//// Functions return #(new_state, commands) tuples for the actor to execute.
////
//// ## Task lifecycle
////
//// pending → ready → running → done
////                         ↘ failed (retry?) → cancelled (cascade)
////
//// ## Usage
////
//// ```gleam
//// let #(state, cmds) = pure.start_graph(state, my_graph)
//// let #(state, cmds) = pure.task_completed(state, "task_a")
//// let #(state, cmds) = pure.task_failed(state, "task_b", "timeout")
//// ```

import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import supernova/core/project/types.{
  type OrchestratorCommand, type OrchestratorState, CancelTask, LaunchTask,
  OrchestratorDone, OrchestratorFailed, OrchestratorRunning, OrchestratorState,
  ReportProgress,
}
import supernova/core/task_graph

// ============================================================================
// Public API
// ============================================================================

/// Load a task graph and start executing it.
///
/// Marks all root tasks (no dependencies) as Running and emits LaunchTask
/// commands for each. Returns the updated state and commands.
pub fn start_graph(
  state: OrchestratorState,
  graph: task_graph.TaskGraph,
) -> #(OrchestratorState, List(OrchestratorCommand)) {
  let ready = task_graph.ready_tasks(graph, [])

  // Mark ready tasks as Running in the graph so they won't re-appear
  let running_graph =
    list.fold(ready, graph, fn(g, id) { task_graph.mark_running(g, id) })

  let phase = case list.is_empty(ready) && dict.is_empty(graph.nodes) {
    True -> OrchestratorDone
    False -> OrchestratorRunning
  }

  let new_state =
    OrchestratorState(
      ..state,
      graph: running_graph,
      phase: phase,
      running: ready,
    )

  let commands =
    list.flat_map(ready, fn(id) {
      let name = get_task_name(running_graph, id)
      [
        LaunchTask(task_id: id, task_name: name),
        ReportProgress(task_id: id, status: "running", message: "Task started"),
      ]
    })

  #(new_state, commands)
}

/// Report that a task completed successfully.
///
/// Updates the graph status, finds newly-ready tasks, and emits
/// LaunchTask commands for each. Transitions to Done if all tasks finished.
pub fn task_completed(
  state: OrchestratorState,
  task_id: String,
) -> #(OrchestratorState, List(OrchestratorCommand)) {
  let new_graph = task_graph.mark_done(state.graph, task_id)
  let new_completed = [task_id, ..state.completed]
  let new_running = list.filter(state.running, fn(id) { id != task_id })

  // Find tasks whose deps are now all satisfied
  let newly_ready = task_graph.ready_tasks(new_graph, new_completed)

  // Mark them Running in graph
  let final_graph =
    list.fold(newly_ready, new_graph, fn(g, id) {
      task_graph.mark_running(g, id)
    })

  let new_state =
    OrchestratorState(
      ..state,
      graph: final_graph,
      completed: new_completed,
      running: list.append(new_running, newly_ready),
    )

  let final_state = check_phase(new_state)

  let launch_commands =
    list.flat_map(newly_ready, fn(id) {
      let name = get_task_name(final_graph, id)
      [
        LaunchTask(task_id: id, task_name: name),
        ReportProgress(task_id: id, status: "running", message: "Task started"),
      ]
    })

  let commands =
    list.append(
      [
        ReportProgress(
          task_id: task_id,
          status: "done",
          message: "Task completed successfully",
        ),
      ],
      launch_commands,
    )

  #(final_state, commands)
}

/// Report that a task failed.
///
/// If retries remain (per config), re-launches the task.
/// Otherwise, permanently fails it and cascades cancellation to all
/// transitive dependents, transitioning to OrchestratorFailed.
pub fn task_failed(
  state: OrchestratorState,
  task_id: String,
  reason: String,
) -> #(OrchestratorState, List(OrchestratorCommand)) {
  let current_retries =
    dict.get(state.retry_counts, task_id) |> result.unwrap(0)
  let max_retries = get_max_retries(state, task_id)

  case current_retries < max_retries {
    True -> {
      // Retry: increment count and re-launch
      let new_counts =
        dict.insert(state.retry_counts, task_id, current_retries + 1)
      let new_state = OrchestratorState(..state, retry_counts: new_counts)
      let name = get_task_name(state.graph, task_id)
      let attempt = int.to_string(current_retries + 1)
      let commands = [
        ReportProgress(
          task_id: task_id,
          status: "retrying",
          message: "Retry attempt " <> attempt <> ": " <> reason,
        ),
        LaunchTask(task_id: task_id, task_name: name),
      ]
      #(new_state, commands)
    }

    False -> {
      // Permanent failure: update graph, cascade-cancel all descendants
      let new_graph = task_graph.mark_failed(state.graph, task_id)
      let new_failed = [task_id, ..state.failed]
      let new_running = list.filter(state.running, fn(id) { id != task_id })

      let descendants = task_graph.get_descendants(state.graph, task_id)

      // Cancel descendants in graph; track which were running (need CancelTask)
      let #(graph_cancelled, running_descendants) =
        list.fold(descendants, #(new_graph, []), fn(acc, desc_id) {
          let #(g, running_deps) = acc
          let new_g = task_graph.mark_cancelled(g, desc_id)
          let was_running = list.contains(state.running, desc_id)
          let new_running_deps = case was_running {
            True -> [desc_id, ..running_deps]
            False -> running_deps
          }
          #(new_g, new_running_deps)
        })

      // Remove cancelled tasks from running list
      let final_running =
        list.filter(new_running, fn(id) { !list.contains(descendants, id) })
      let new_cancelled = list.append(state.cancelled, descendants)

      let new_state =
        OrchestratorState(
          ..state,
          graph: graph_cancelled,
          failed: new_failed,
          running: final_running,
          cancelled: new_cancelled,
          phase: OrchestratorFailed(
            reason: "Task " <> task_id <> " failed: " <> reason,
          ),
        )

      // Commands: report failure, report cascade cancellations, then send CancelTask
      let cancel_report_cmds =
        list.map(descendants, fn(id) {
          ReportProgress(
            task_id: id,
            status: "cancelled",
            message: "Cancelled: dependency " <> task_id <> " failed",
          )
        })
      let cancel_cmds =
        list.map(running_descendants, fn(id) { CancelTask(task_id: id) })

      let commands =
        list.flatten([
          [
            ReportProgress(task_id: task_id, status: "failed", message: reason),
          ],
          cancel_report_cmds,
          cancel_cmds,
        ])

      #(new_state, commands)
    }
  }
}

/// Get the current execution phase.
pub fn get_phase(state: OrchestratorState) -> types.OrchestratorPhase {
  state.phase
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Look up a task name from the graph (falls back to task_id if not found).
fn get_task_name(graph: task_graph.TaskGraph, task_id: String) -> String {
  case dict.get(graph.nodes, task_id) {
    Ok(node) -> node.name
    Error(_) -> task_id
  }
}

/// Resolve max retries for a specific task (per-task override > default).
fn get_max_retries(state: OrchestratorState, task_id: String) -> Int {
  case dict.get(state.config.task_retry_overrides, task_id) {
    Ok(max) -> max
    Error(_) -> state.config.default_max_retries
  }
}

/// Update the orchestrator phase based on terminal task counts.
///
/// If all graph nodes are Done/Failed/Cancelled → transitions to Done or Failed.
/// No-ops if any task is still pending/running.
fn check_phase(state: OrchestratorState) -> OrchestratorState {
  let nodes = dict.values(state.graph.nodes)
  case list.is_empty(nodes) {
    True -> state
    False -> {
      let all_terminal =
        list.all(nodes, fn(node) {
          case node.status {
            task_graph.Done | task_graph.Failed | task_graph.Cancelled -> True
            _ -> False
          }
        })
      case all_terminal {
        False -> state
        True -> {
          let any_failed =
            list.any(nodes, fn(node) { node.status == task_graph.Failed })
          case any_failed {
            True ->
              case state.phase {
                OrchestratorFailed(_) -> state
                _ ->
                  OrchestratorState(
                    ..state,
                    phase: OrchestratorFailed(reason: "Some tasks failed"),
                  )
              }
            False -> OrchestratorState(..state, phase: OrchestratorDone)
          }
        }
      }
    }
  }
}
