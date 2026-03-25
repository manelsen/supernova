//// Agent Queue — Actor
////
//// Singleton actor that manages per-agent priority job queues.
//// Delegates pure logic to the pure module, executes side effects via FFI.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(queue) = actor.start()
//// let assert Ok(job_id) = actor.enqueue(queue, "agent_1", "do task", High, 0)
//// let assert Ok(job) = actor.next(queue, "agent_1")
//// actor.stop(queue)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/string
import supernova/core/agent_queue/pure
import supernova/core/agent_queue/types.{
  type AgentQueueState, type Job, type Priority,
}

// ============================================================================
// FFI — Timestamp (Erlang)
// ============================================================================

/// Get current timestamp in milliseconds (Erlang FFI).
@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

// ============================================================================
// Types
// ============================================================================

/// Messages that the agent queue actor handles.
pub type QueueMessage {
  /// Enqueue a new job
  Enqueue(
    reply_to: Subject(Result(String, String)),
    agent_id: String,
    prompt: String,
    priority: Priority,
    deadline: Int,
  )
  /// Get the next job by priority
  Next(reply_to: Subject(Result(Job, String)), agent_id: String)
  /// Cancel a job by ID
  Cancel(reply_to: Subject(Result(Nil, String)), job_id: String)
  /// Drain all jobs for an agent
  Drain(reply_to: Subject(List(Job)), agent_id: String)
  /// List jobs for an agent (peek, no removal)
  ListJobs(reply_to: Subject(List(Job)), agent_id: String)
  /// Count jobs for an agent
  Count(reply_to: Subject(Int), agent_id: String)
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running agent queue actor.
pub type AgentQueueHandle =
  Subject(QueueMessage)

// ============================================================================
// Error Formatting
// ============================================================================

/// Format a QueueError as a string.
fn format_error(err: types.QueueError) -> String {
  case err {
    types.DeadlineExpired(job_id, deadline, _now) ->
      "Deadline expired for job "
      <> job_id
      <> " at "
      <> string.inspect(deadline)
    types.JobNotFound(job_id) -> "Job not found: " <> job_id
    types.QueueEmpty(agent_id) -> "Queue empty for agent: " <> agent_id
  }
}

// ============================================================================
// Actor Handler
// ============================================================================

/// Handle incoming messages and update state.
fn handle_message(
  state: AgentQueueState,
  message: QueueMessage,
) -> actor.Next(AgentQueueState, QueueMessage) {
  case message {
    Enqueue(reply_to, agent_id, prompt, priority, deadline) -> {
      let now = ffi_current_timestamp()
      let #(new_state, result) =
        pure.enqueue(state, agent_id, prompt, priority, deadline, now)
      case result {
        Ok(job_id) -> actor.send(reply_to, Ok(job_id))
        Error(err) -> actor.send(reply_to, Error(format_error(err)))
      }
      actor.continue(new_state)
    }

    Next(reply_to, agent_id) -> {
      let now = ffi_current_timestamp()
      let #(new_state, result) = pure.next(state, agent_id, now)
      case result {
        Ok(job) -> actor.send(reply_to, Ok(job))
        Error(err) -> actor.send(reply_to, Error(format_error(err)))
      }
      actor.continue(new_state)
    }

    Cancel(reply_to, job_id) -> {
      let #(new_state, result) = pure.cancel(state, job_id)
      case result {
        Ok(_) -> actor.send(reply_to, Ok(Nil))
        Error(err) -> actor.send(reply_to, Error(format_error(err)))
      }
      actor.continue(new_state)
    }

    Drain(reply_to, agent_id) -> {
      let #(new_state, jobs) = pure.drain(state, agent_id)
      actor.send(reply_to, jobs)
      actor.continue(new_state)
    }

    ListJobs(reply_to, agent_id) -> {
      let jobs = pure.list_jobs(state, agent_id)
      actor.send(reply_to, jobs)
      actor.continue(state)
    }

    Count(reply_to, agent_id) -> {
      let n = pure.count(state, agent_id)
      actor.send(reply_to, n)
      actor.continue(state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start the agent queue actor.
pub fn start() -> Result(AgentQueueHandle, actor.StartError) {
  let initial_state = types.initial_state()

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Enqueue a new job for an agent.
pub fn enqueue(
  queue: AgentQueueHandle,
  agent_id: String,
  prompt: String,
  priority: Priority,
  deadline: Int,
) -> Result(String, String) {
  actor.call(queue, waiting: 5000, sending: Enqueue(
    _,
    agent_id,
    prompt,
    priority,
    deadline,
  ))
}

/// Get the next job for an agent, ordered by priority.
pub fn next(queue: AgentQueueHandle, agent_id: String) -> Result(Job, String) {
  actor.call(queue, waiting: 5000, sending: Next(_, agent_id))
}

/// Cancel a job by its ID.
pub fn cancel(queue: AgentQueueHandle, job_id: String) -> Result(Nil, String) {
  actor.call(queue, waiting: 5000, sending: Cancel(_, job_id))
}

/// Drain all jobs for an agent (for graceful shutdown).
pub fn drain(queue: AgentQueueHandle, agent_id: String) -> List(Job) {
  actor.call(queue, waiting: 5000, sending: Drain(_, agent_id))
}

/// List all jobs for an agent without removing them (peek).
pub fn list_jobs(queue: AgentQueueHandle, agent_id: String) -> List(Job) {
  actor.call(queue, waiting: 5000, sending: ListJobs(_, agent_id))
}

/// Count jobs for an agent.
pub fn count(queue: AgentQueueHandle, agent_id: String) -> Int {
  actor.call(queue, waiting: 5000, sending: Count(_, agent_id))
}

/// Stop the agent queue actor.
pub fn stop(queue: AgentQueueHandle) -> Nil {
  actor.call(queue, waiting: 5000, sending: Stop)
}
