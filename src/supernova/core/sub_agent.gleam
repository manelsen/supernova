//// Sub-Agent System for Supernova
////
//// Enables spawning child agents to parallelize complex tasks.
//// Sub-agents inherit workspace context from their parent and can be
//// monitored, awaited, and cancelled in cascade.
////
//// ## Usage
////
//// ```gleam
//// let config = sub_agent.default_config()
//// let assert Ok(agent) = sub_agent.spawn("parent-001", "Analyze codebase", config)
//// let assert Ok(result) = sub_agent.await(agent, 30_000)
//// sub_agent.cancel(agent)
//// ```

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import supernova/metrics/actor as metrics_actor
import supernova/metrics/global as metrics_global

// ============================================================================
// Types
// ============================================================================

/// Status of a sub-agent execution (internal tracking).
pub type SubAgentStatus {
  /// Agent is initializing
  SubAgentInitializing
  /// Agent is running the goal
  SubAgentRunning
  /// Agent completed successfully
  SubAgentCompleted
  /// Agent was cancelled
  SubAgentCancelled
  /// Agent encountered an error
  SubAgentFailed(reason: String)
  /// Agent timed out
  SubAgentTimedOut
}

/// Semantic outcome of a sub-agent result (for orchestrator decisions).
pub type SubAgentResultStatus {
  /// Task completed fully and successfully
  ResultSuccess
  /// Task failed with an error
  ResultFailure
  /// Task completed partially (e.g., some steps done, some skipped)
  ResultPartial
}

/// Structured result returned by a sub-agent.
pub type SubAgentResult {
  SubAgentResult(
    /// Unique identifier for this sub-agent
    agent_id: String,
    /// Semantic outcome of the execution
    status: SubAgentResultStatus,
    /// Output produced by the agent (Dynamic to support any type)
    output: Dynamic,
    /// File paths of any artifacts produced by the agent
    artifacts: List(String),
    /// Number of LLM tokens consumed (0 in mock)
    tokens_used: Int,
    /// Wall-clock duration in milliseconds
    duration_ms: Int,
  )
}

/// Configuration for a sub-agent.
pub type SubAgentConfig {
  SubAgentConfig(
    /// Timeout in milliseconds for the agent to complete its goal
    timeout_ms: Int,
    /// Maximum recursion depth for nested sub-agents
    max_depth: Int,
    /// Current depth in the agent hierarchy
    current_depth: Int,
  )
}

/// Messages that can be sent to a sub-agent actor.
pub type SubAgentMessage {
  /// Execute the goal (internal trigger after spawn)
  ExecuteGoal
  /// Get the current result of the sub-agent
  GetResult(reply_to: Subject(SubAgentResult))
  /// Get the current status
  GetStatus(reply_to: Subject(SubAgentStatus))
  /// Cancel the sub-agent and all its children (cascade)
  Cancel(reply_to: Subject(Result(Nil, String)))
  /// Wait for the result with a timeout
  AwaitResult(
    reply_to: Subject(Result(SubAgentResult, String)),
    timeout_ms: Int,
  )
  /// Stop the sub-agent gracefully
  Stop(reply_to: Subject(Nil))
}

/// Internal state of a sub-agent actor.
pub type SubAgentState {
  SubAgentState(
    /// Unique identifier for this sub-agent
    agent_id: String,
    /// ID of the parent agent
    parent_id: String,
    /// The goal to execute
    goal: String,
    /// Configuration
    config: SubAgentConfig,
    /// Current status
    status: SubAgentStatus,
    /// Output produced (if any)
    output: Option(String),
    /// Error message (if any)
    error: Option(String),
    /// Child sub-agents spawned by this agent
    children: List(Subject(SubAgentMessage)),
    /// Artifact file paths produced by this agent
    artifacts: List(String),
    /// LLM tokens used (0 in mock)
    tokens_used: Int,
  )
}

/// A handle to a running sub-agent.
pub type SubAgent =
  Subject(SubAgentMessage)

// ============================================================================
// Logging Helpers
// ============================================================================

/// Log level for structured logging.
type LogLevel {
  Debug
  Info
  Warning
  LogError
}

/// Format log level to string.
fn log_level_to_string(level: LogLevel) -> String {
  case level {
    Debug -> "DEBUG"
    Info -> "INFO"
    Warning -> "WARN"
    LogError -> "ERROR"
  }
}

/// Format status to string for logging.
fn format_status(status: SubAgentStatus) -> String {
  case status {
    SubAgentInitializing -> "initializing"
    SubAgentRunning -> "running"
    SubAgentCompleted -> "completed"
    SubAgentCancelled -> "cancelled"
    SubAgentFailed(reason) -> "failed: " <> reason
    SubAgentTimedOut -> "timed_out"
  }
}

/// Log a structured message (internal helper).
fn log(
  level: LogLevel,
  component: String,
  message: String,
  attrs: List(#(String, String)),
) -> String {
  let level_str = log_level_to_string(level)

  let attrs_str =
    attrs
    |> list.map(fn(pair) {
      let #(key, value) = pair
      key <> "=" <> value
    })
    |> string.join(" ")

  case attrs_str {
    "" -> "[" <> level_str <> "] [" <> component <> "] " <> message
    _ ->
      "["
      <> level_str
      <> "] ["
      <> component
      <> "] "
      <> message
      <> " | "
      <> attrs_str
  }
}

// ============================================================================
// Actor Implementation
// ============================================================================

/// Build a SubAgentResult from the current SubAgentState.
fn state_to_result(state: SubAgentState) -> SubAgentResult {
  let result_status = case state.status {
    SubAgentCompleted -> ResultSuccess
    SubAgentFailed(_) -> ResultFailure
    SubAgentTimedOut -> ResultFailure
    SubAgentCancelled -> ResultPartial
    _ -> ResultPartial
  }
  let output_str = option.unwrap(state.output, "")
  SubAgentResult(
    agent_id: state.agent_id,
    status: result_status,
    output: dynamic.string(output_str),
    artifacts: state.artifacts,
    tokens_used: state.tokens_used,
    duration_ms: 0,
  )
}

/// Execute the goal (mock implementation for now).
/// In a real implementation, this would dispatch to the executor.
fn execute_goal(
  state: SubAgentState,
) -> #(SubAgentState, List(#(String, String))) {
  let _ =
    log(Info, "sub_agent", "Executing goal", [
      #("agent_id", state.agent_id),
      #("goal", state.goal),
    ])

  // Simulate goal execution - in production this would call the executor
  let output =
    "Goal '" <> state.goal <> "' completed by agent " <> state.agent_id

  // Mock: produce one artifact per goal for testing purposes
  let artifact_path = "/tmp/" <> state.agent_id <> "/result.txt"

  let new_state =
    SubAgentState(
      ..state,
      status: SubAgentCompleted,
      output: Some(output),
      artifacts: [artifact_path],
      tokens_used: 42,
    )

  record_agent_stopped("completed")
  #(new_state, [])
}

fn is_terminal(status: SubAgentStatus) -> Bool {
  case status {
    SubAgentCompleted
    | SubAgentCancelled
    | SubAgentFailed(_)
    | SubAgentTimedOut -> True
    SubAgentInitializing | SubAgentRunning -> False
  }
}

/// Cancel all child agents recursively (cascade cancellation).
fn cancel_children(children: List(Subject(SubAgentMessage))) -> Nil {
  list.each(children, fn(child) {
    let reply_subject = process.new_subject()
    actor.send(child, Cancel(reply_subject))
    // Fire and forget - don't wait for child cancellation
    Nil
  })
}

/// Handle incoming messages and update state.
fn handle_message(
  state: SubAgentState,
  message: SubAgentMessage,
) -> actor.Next(SubAgentState, SubAgentMessage) {
  case message {
    ExecuteGoal -> {
      let _ =
        log(Info, "sub_agent", "ExecuteGoal", [
          #("agent_id", state.agent_id),
          #("parent_id", state.parent_id),
        ])

      // Check depth limit
      case state.config.current_depth >= state.config.max_depth {
        True -> {
          let error_msg = "Max depth exceeded"
          let _ =
            log(LogError, "sub_agent", error_msg, [
              #("agent_id", state.agent_id),
              #("depth", string.inspect(state.config.current_depth)),
            ])
          let new_state =
            SubAgentState(
              ..state,
              status: SubAgentFailed(reason: error_msg),
              error: Some(error_msg),
            )
          record_agent_stopped("failed")
          actor.continue(new_state)
        }
        False -> {
          // Update status to running
          let running_state = SubAgentState(..state, status: SubAgentRunning)

          // Execute the goal
          let #(final_state, _commands) = execute_goal(running_state)

          actor.continue(final_state)
        }
      }
    }

    GetResult(reply_to) -> {
      let _ =
        log(Debug, "sub_agent", "GetResult", [
          #("agent_id", state.agent_id),
          #("status", format_status(state.status)),
        ])

      actor.send(reply_to, state_to_result(state))
      actor.continue(state)
    }

    GetStatus(reply_to) -> {
      let _ =
        log(Debug, "sub_agent", "GetStatus", [
          #("agent_id", state.agent_id),
          #("status", format_status(state.status)),
        ])

      actor.send(reply_to, state.status)
      actor.continue(state)
    }

    Cancel(reply_to) -> {
      let _ =
        log(Info, "sub_agent", "Cancel", [
          #("agent_id", state.agent_id),
          #("children_count", string.inspect(list.length(state.children))),
        ])

      // Cancel all children first (cascade)
      cancel_children(state.children)

      // The active gauge is lowered only on the first terminal transition:
      // cancelling an agent that already finished does not lower it again.
      case is_terminal(state.status) {
        True -> Nil
        False -> record_agent_stopped("cancelled")
      }
      let new_state =
        SubAgentState(..state, status: SubAgentCancelled, children: [])

      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    AwaitResult(reply_to, timeout_ms) -> {
      let _ =
        log(Debug, "sub_agent", "AwaitResult", [
          #("agent_id", state.agent_id),
          #("timeout_ms", string.inspect(timeout_ms)),
          #("status", format_status(state.status)),
        ])

      actor.send(reply_to, Ok(state_to_result(state)))
      actor.continue(state)
    }

    Stop(reply_to) -> {
      let _ = log(Info, "sub_agent", "Stop", [#("agent_id", state.agent_id)])

      // Cancel children before stopping
      cancel_children(state.children)

      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Create a default configuration for a sub-agent.
pub fn default_config() -> SubAgentConfig {
  SubAgentConfig(timeout_ms: 30_000, max_depth: 5, current_depth: 0)
}

/// Create a configuration with custom timeout.
pub fn config_with_timeout(timeout_ms: Int) -> SubAgentConfig {
  SubAgentConfig(timeout_ms: timeout_ms, max_depth: 5, current_depth: 0)
}

/// Create a configuration with custom depth settings.
pub fn config_with_depth(max_depth: Int, current_depth: Int) -> SubAgentConfig {
  SubAgentConfig(
    timeout_ms: 30_000,
    max_depth: max_depth,
    current_depth: current_depth,
  )
}

/// Generate a unique agent ID based on parent ID and a counter.
fn generate_agent_id(parent_id: String) -> String {
  parent_id <> "-sub-" <> string.inspect(erlang_unique_int())
}

/// Get a unique integer (mock for now, would use FFI in production).
@external(erlang, "supernova_sub_agent_ffi", "unique_int")
fn erlang_unique_int() -> Int

/// Spawn a new sub-agent with the given parent ID, goal, and configuration.
///
/// Creates a child agent that inherits workspace context from the parent.
/// Returns the Subject handle to communicate with the sub-agent.
pub fn spawn(
  parent_id: String,
  goal: String,
  config: SubAgentConfig,
) -> Result(SubAgent, actor.StartError) {
  let agent_id = generate_agent_id(parent_id)

  let initial_state =
    SubAgentState(
      agent_id: agent_id,
      parent_id: parent_id,
      goal: goal,
      config: config,
      status: SubAgentInitializing,
      output: None,
      error: None,
      children: [],
      artifacts: [],
      tokens_used: 0,
    )

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> {
      // Trigger goal execution
      actor.send(started.data, ExecuteGoal)
      record_agent_spawned()
      Ok(started.data)
    }
    Error(error) -> Error(error)
  }
}

/// Cancel a sub-agent and all its children (cascade cancellation).
///
/// Sends a cancellation signal to the agent and recursively cancels
/// all child agents it has spawned.
pub fn cancel(agent: SubAgent) -> Result(Nil, String) {
  let reply_subject = process.new_subject()
  actor.send(agent, Cancel(reply_subject))

  case process.receive(reply_subject, 5000) {
    Ok(result) -> result
    Error(_) -> Error("Timeout waiting for cancellation")
  }
}

/// Wait for a sub-agent to complete and return its result.
///
/// Blocks until the agent completes, is cancelled, or the timeout expires.
pub fn await(
  agent: SubAgent,
  timeout_ms: Int,
) -> Result(SubAgentResult, String) {
  let reply_subject = process.new_subject()
  actor.send(agent, AwaitResult(reply_subject, timeout_ms))

  case process.receive(reply_subject, timeout_ms) {
    Ok(result) -> result
    Error(_) -> Error("Timeout waiting for sub-agent result")
  }
}

/// Get the current result of a sub-agent without waiting.
pub fn get_result(agent: SubAgent) -> SubAgentResult {
  actor.call(agent, waiting: 5000, sending: GetResult)
}

/// Get the current status of a sub-agent.
pub fn get_status(agent: SubAgent) -> SubAgentStatus {
  actor.call(agent, waiting: 5000, sending: GetStatus)
}

/// Stop a sub-agent gracefully.
pub fn stop(agent: SubAgent) -> Nil {
  actor.call(agent, waiting: 5000, sending: Stop)
}

fn record_agent_spawned() {
  case metrics_global.get_metrics() {
    option.Some(metrics) -> {
      metrics_actor.inc_counter(metrics, "agents_spawned_total", [])
      metrics_actor.add_gauge(metrics, "agents_active", 1, [])
    }
    option.None -> Nil
  }
}

fn record_agent_stopped(status: String) {
  case metrics_global.get_metrics() {
    option.Some(metrics) -> {
      metrics_actor.inc_counter(metrics, "agents_stopped_total", [
        #("status", status),
      ])
      metrics_actor.add_gauge(metrics, "agents_active", -1, [])
    }
    option.None -> Nil
  }
}
