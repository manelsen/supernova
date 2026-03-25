//// Agent Queue — Pure Functions
////
//// Pure functions for per-agent priority job queue. No FFI, no side effects.
//// Functions take state and return new state + commands for the actor to execute.
////
//// ## Usage
////
//// ```gleam
//// let #(state, result) = pure.enqueue(state, "agent_1", "do task", High, 0, 1000)
//// let #(state, result) = pure.next(state, "agent_1", 1500)
//// ```

import gleam/dict
import gleam/list
import gleam/string
import supernova/core/agent_queue/types.{
  type AgentQueueState, type Job, type Priority, type QueueError,
  AgentQueueState, DeadlineExpired, Job, JobNotFound, QueueEmpty,
}

// ============================================================================
// Public API
// ============================================================================

/// Enqueue a new job for an agent.
///
/// Returns `#(new_state, Ok(job_id))` on success.
/// Returns `#(state, Error(...))` if the deadline has already expired.
pub fn enqueue(
  state: AgentQueueState,
  agent_id: String,
  prompt: String,
  priority: Priority,
  deadline: Int,
  now: Int,
) -> #(AgentQueueState, Result(String, QueueError)) {
  // Check if deadline is valid (non-zero and already passed)
  case deadline > 0 && deadline <= now {
    True -> #(state, Error(DeadlineExpired("", deadline, now)))
    False -> {
      let job_id = "job_" <> string.inspect(state.next_id)
      let job =
        Job(
          id: job_id,
          agent_id: agent_id,
          prompt: prompt,
          priority: priority,
          deadline: deadline,
          created_at: now,
        )
      let current_jobs = case dict.get(state.queues, agent_id) {
        Ok(jobs) -> jobs
        Error(_) -> []
      }
      let new_queues =
        dict.insert(state.queues, agent_id, list.append(current_jobs, [job]))
      let new_state =
        AgentQueueState(queues: new_queues, next_id: state.next_id + 1)
      #(new_state, Ok(job_id))
    }
  }
}

/// Get the next job for an agent, ordered by priority.
///
/// Returns `#(new_state, Ok(job))` on success.
/// Returns `#(state, Error(...))` if queue is empty or top job's deadline expired.
pub fn next(
  state: AgentQueueState,
  agent_id: String,
  now: Int,
) -> #(AgentQueueState, Result(Job, QueueError)) {
  case dict.get(state.queues, agent_id) {
    Ok(jobs) ->
      case sort_by_priority(jobs) {
        [] -> #(state, Error(QueueEmpty(agent_id)))
        [first, ..rest] ->
          case first.deadline > 0 && first.deadline <= now {
            True -> {
              // Deadline expired — remove this job and try the next one
              let new_queues = dict.insert(state.queues, agent_id, rest)
              let new_state = AgentQueueState(..state, queues: new_queues)
              // Recurse to try the next job
              next(new_state, agent_id, now)
            }
            False -> {
              let new_queues = dict.insert(state.queues, agent_id, rest)
              let new_state = AgentQueueState(..state, queues: new_queues)
              #(new_state, Ok(first))
            }
          }
      }
    Error(_) -> #(state, Error(QueueEmpty(agent_id)))
  }
}

/// Cancel a job by its ID.
///
/// Searches across all agents for the job.
/// Returns `#(new_state, Ok(Nil))` on success.
/// Returns `#(state, Error(...))` if job not found.
pub fn cancel(
  state: AgentQueueState,
  job_id: String,
) -> #(AgentQueueState, Result(Nil, QueueError)) {
  let all_jobs = dict.to_list(state.queues)
  case find_and_remove(all_jobs, job_id, []) {
    Ok(new_queues) -> #(
      AgentQueueState(..state, queues: dict.from_list(new_queues)),
      Ok(Nil),
    )
    Error(_) -> #(state, Error(JobNotFound(job_id)))
  }
}

/// Drain all jobs for an agent (for graceful shutdown).
///
/// Returns all jobs sorted by priority, removing them from the queue.
pub fn drain(
  state: AgentQueueState,
  agent_id: String,
) -> #(AgentQueueState, List(Job)) {
  case dict.get(state.queues, agent_id) {
    Ok(jobs) -> {
      let sorted = sort_by_priority(jobs)
      let new_queues = dict.delete(state.queues, agent_id)
      #(AgentQueueState(..state, queues: new_queues), sorted)
    }
    Error(_) -> #(state, [])
  }
}

/// List all jobs for an agent without removing them (peek).
pub fn list_jobs(state: AgentQueueState, agent_id: String) -> List(Job) {
  case dict.get(state.queues, agent_id) {
    Ok(jobs) -> sort_by_priority(jobs)
    Error(_) -> []
  }
}

/// Count jobs for an agent.
pub fn count(state: AgentQueueState, agent_id: String) -> Int {
  case dict.get(state.queues, agent_id) {
    Ok(jobs) -> list.length(jobs)
    Error(_) -> 0
  }
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Sort jobs by priority (High first, then Normal, then Low).
/// Within the same priority, preserves original insertion order (FIFO).
fn sort_by_priority(jobs: List(Job)) -> List(Job) {
  let high = list.filter(jobs, fn(job) { job.priority == types.High })
  let normal = list.filter(jobs, fn(job) { job.priority == types.Normal })
  let low = list.filter(jobs, fn(job) { job.priority == types.Low })

  high
  |> list.append(normal)
  |> list.append(low)
}

/// Find and remove a job by ID across all agent queues.
fn find_and_remove(
  entries: List(#(String, List(Job))),
  job_id: String,
  acc: List(#(String, List(Job))),
) -> Result(List(#(String, List(Job))), Nil) {
  case entries {
    [] -> Error(Nil)
    [#(agent_id, jobs), ..rest] ->
      case list.filter(jobs, fn(j) { j.id != job_id }) {
        filtered ->
          case list.length(filtered) < list.length(jobs) {
            True -> {
              // Found and removed
              let remaining = case list.is_empty(filtered) {
                True -> acc
                False -> list.append(acc, [#(agent_id, filtered)])
              }
              Ok(list.append(remaining, rest))
            }
            False ->
              find_and_remove(
                rest,
                job_id,
                list.append(acc, [#(agent_id, jobs)]),
              )
          }
      }
  }
}
