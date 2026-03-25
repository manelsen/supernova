//// Agent Queue — Pure Types
////
//// Pure data structures for per-agent priority job queue.
//// No FFI, no side effects.
//// These types define the domain model for prioritized job scheduling.

import gleam/dict.{type Dict}

// ============================================================================
// Types
// ============================================================================
/// Priority levels for jobs in the queue.
pub type Priority {
  High
  Normal
  Low
}

/// A job in the agent queue.
pub type Job {
  Job(
    /// Unique job identifier
    id: String,
    /// Agent this job belongs to
    agent_id: String,
    /// The prompt/task to execute
    prompt: String,
    /// Priority level
    priority: Priority,
    /// Deadline timestamp (milliseconds). 0 means no deadline.
    deadline: Int,
    /// When the job was created (milliseconds)
    created_at: Int,
  )
}

/// Error type for queue operations.
pub type QueueError {
  /// Deadline has already passed
  DeadlineExpired(job_id: String, deadline: Int, now: Int)
  /// Job not found
  JobNotFound(job_id: String)
  /// Queue is empty for the agent
  QueueEmpty(agent_id: String)
}

/// Command pattern for I/O operations.
/// Pure functions return commands; the actor executes them.
pub type QueueCommand {
  /// Emit telemetry for job enqueue
  EmitEnqueueTelemetry(agent_id: String, job_id: String, priority: String)
  /// Emit telemetry for job dequeue
  EmitDequeueTelemetry(agent_id: String, job_id: String)
  /// Write audit log for job cancellation
  WriteCancelAudit(agent_id: String, job_id: String, timestamp: Int)
}

/// The agent queue state maintained by the actor.
pub type AgentQueueState {
  AgentQueueState(
    /// Per-agent job queues
    queues: Dict(String, List(Job)),
    /// Counter for generating unique job IDs
    next_id: Int,
  )
}

// ============================================================================
// Default Values
// ============================================================================

/// Create an initial empty agent queue state.
pub fn initial_state() -> AgentQueueState {
  AgentQueueState(queues: dict.new(), next_id: 0)
}
