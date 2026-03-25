//// Project Orchestrator — Actor
////
//// OTP actor that executes a TaskGraph by spawning sub-agents for each
//// task and writing progress to an optional Blackboard.
////
//// Delegates all pure logic to the pure module; side effects (spawning,
//// cancelling sub-agents, Blackboard writes) are executed here.
////
//// ## Usage
////
//// ```gleam
//// let config = types.default_config("proj_001")
//// let assert Ok(orch) = actor.start(config, None)
//// let assert Ok(Nil) = actor.start_graph(orch, my_graph)
//// actor.task_completed(orch, "task_a")
//// let phase = actor.get_phase(orch)
//// actor.stop(orch)
//// ```

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import supernova/core/blackboard
import supernova/core/project/pure
import supernova/core/project/types.{
  type OrchestratorCommand, type OrchestratorConfig, type OrchestratorPhase,
  type OrchestratorState, CancelTask, LaunchTask, ReportProgress,
}
import supernova/core/sub_agent.{type SubAgent, type SubAgentResult}
import supernova/core/task_graph.{type TaskGraph}

// ============================================================================
// Types
// ============================================================================

/// Messages handled by the orchestrator actor.
pub type OrchestratorMessage {
  /// Load and start executing a task graph
  StartGraph(reply_to: Subject(Result(Nil, String)), graph: TaskGraph)
  /// Report that a task completed — carries the typed SubAgentResult for semantic decisions
  TaskCompleted(reply_to: Subject(Nil), task_id: String, result: SubAgentResult)
  /// Report that a task failed
  TaskFailed(reply_to: Subject(Nil), task_id: String, reason: String)
  /// Get the current execution phase
  GetPhase(reply_to: Subject(OrchestratorPhase))
  /// Stop the actor (cancels all running sub-agents)
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running orchestrator actor.
pub type OrchestratorHandle =
  Subject(OrchestratorMessage)

/// Internal actor state: pure state + side-effectful handles.
type ActorState {
  ActorState(
    /// Orchestrator pure state (task graph, phases, retry counts, etc.)
    pure: OrchestratorState,
    /// Sub-agent handles indexed by task_id
    agents: Dict(String, SubAgent),
    /// Optional Blackboard for progress reporting
    blackboard: Option(blackboard.Blackboard),
  )
}

// ============================================================================
// Command Execution
// ============================================================================

/// Execute a list of commands returned by pure functions.
///
/// Returns the updated agents dict (LaunchTask adds, CancelTask removes).
fn execute_commands(
  commands: List(OrchestratorCommand),
  agents: Dict(String, SubAgent),
  bb: Option(blackboard.Blackboard),
  project_id: String,
) -> Dict(String, SubAgent) {
  list.fold(commands, agents, fn(acc, cmd) {
    case cmd {
      LaunchTask(task_id, task_name) -> {
        case
          sub_agent.spawn(project_id, task_name, sub_agent.default_config())
        {
          Ok(agent) -> dict.insert(acc, task_id, agent)
          Error(_) -> acc
        }
      }

      CancelTask(task_id) -> {
        case dict.get(acc, task_id) {
          Ok(agent) -> {
            let _ = sub_agent.cancel(agent)
            dict.delete(acc, task_id)
          }
          Error(_) -> acc
        }
      }

      ReportProgress(task_id, status, _message) -> {
        case bb {
          Some(board) -> {
            blackboard.set(board, "task:" <> task_id, status)
            acc
          }
          None -> acc
        }
      }
    }
  })
}

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: ActorState,
  message: OrchestratorMessage,
) -> actor.Next(ActorState, OrchestratorMessage) {
  case message {
    StartGraph(reply_to, graph) -> {
      let #(new_pure, commands) = pure.start_graph(state.pure, graph)
      let new_agents =
        execute_commands(
          commands,
          state.agents,
          state.blackboard,
          state.pure.config.project_id,
        )
      actor.send(reply_to, Ok(Nil))
      actor.continue(ActorState(..state, pure: new_pure, agents: new_agents))
    }

    TaskCompleted(reply_to, task_id, sub_result) -> {
      // Use result.status to decide: Success/Partial → mark done; Failure → cascade fail
      let #(new_pure, commands) = case sub_result.status {
        sub_agent.ResultSuccess | sub_agent.ResultPartial ->
          pure.task_completed(state.pure, task_id)
        sub_agent.ResultFailure -> {
          let reason =
            decode.run(sub_result.output, decode.string)
            |> result.unwrap("task failed")
          pure.task_failed(state.pure, task_id, reason)
        }
      }
      let new_agents =
        execute_commands(
          commands,
          state.agents,
          state.blackboard,
          state.pure.config.project_id,
        )
      // Remove the completed task's agent from the map
      let cleaned = dict.delete(new_agents, task_id)
      actor.send(reply_to, Nil)
      actor.continue(ActorState(..state, pure: new_pure, agents: cleaned))
    }

    TaskFailed(reply_to, task_id, reason) -> {
      let #(new_pure, commands) = pure.task_failed(state.pure, task_id, reason)
      let new_agents =
        execute_commands(
          commands,
          state.agents,
          state.blackboard,
          state.pure.config.project_id,
        )
      // Remove the failed task's agent (already terminated)
      let cleaned = dict.delete(new_agents, task_id)
      actor.send(reply_to, Nil)
      actor.continue(ActorState(..state, pure: new_pure, agents: cleaned))
    }

    GetPhase(reply_to) -> {
      actor.send(reply_to, pure.get_phase(state.pure))
      actor.continue(state)
    }

    Stop(reply_to) -> {
      // Cancel all running sub-agents
      list.each(dict.values(state.agents), fn(agent) {
        let _ = sub_agent.cancel(agent)
        Nil
      })
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start the orchestrator actor.
///
/// Pass `Some(blackboard)` to report per-task progress to the Blackboard.
pub fn start(
  config: OrchestratorConfig,
  bb: Option(blackboard.Blackboard),
) -> Result(OrchestratorHandle, actor.StartError) {
  let initial =
    ActorState(
      pure: types.initial_state(config),
      agents: dict.new(),
      blackboard: bb,
    )

  case
    actor.new(initial)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Load and begin executing a task graph.
///
/// All root tasks (no unmet dependencies) are launched immediately in parallel.
pub fn start_graph(
  handle: OrchestratorHandle,
  graph: TaskGraph,
) -> Result(Nil, String) {
  actor.call(handle, waiting: 5000, sending: StartGraph(_, graph))
}

/// Report that a task completed, carrying the structured SubAgentResult.
///
/// The orchestrator uses result.status to decide next steps:
/// - ResultSuccess / ResultPartial → mark done, launch newly-ready tasks
/// - ResultFailure → cascade cancel dependents and move to Failed phase
pub fn task_completed(
  handle: OrchestratorHandle,
  task_id: String,
  result: SubAgentResult,
) -> Nil {
  actor.call(handle, waiting: 5000, sending: TaskCompleted(_, task_id, result))
}

/// Report that a task failed.
///
/// If retries remain, the task is re-launched. Otherwise, all dependent
/// tasks are cancelled (cascade) and the orchestrator moves to Failed phase.
pub fn task_failed(
  handle: OrchestratorHandle,
  task_id: String,
  reason: String,
) -> Nil {
  actor.call(handle, waiting: 5000, sending: TaskFailed(_, task_id, reason))
}

/// Get the current execution phase.
pub fn get_phase(handle: OrchestratorHandle) -> OrchestratorPhase {
  actor.call(handle, waiting: 5000, sending: GetPhase)
}

/// Stop the orchestrator gracefully (cancels all running sub-agents).
pub fn stop(handle: OrchestratorHandle) -> Nil {
  actor.call(handle, waiting: 5000, sending: Stop)
}
