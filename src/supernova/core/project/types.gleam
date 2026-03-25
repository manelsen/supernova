//// Project Orchestrator — Types
////
//// Pure data structures for TaskGraph-based orchestration.
//// No FFI, no OTP imports, no side effects.

import gleam/dict.{type Dict}
import supernova/core/task_graph.{type TaskGraph}

// ============================================================================
// Types
// ============================================================================

/// Configuration for the orchestrator (immutable after start).
pub type OrchestratorConfig {
  OrchestratorConfig(
    /// Unique project identifier
    project_id: String,
    /// Default max retries for any task (0 = no retry)
    default_max_retries: Int,
    /// Per-task retry overrides: task_id -> max_retries
    task_retry_overrides: Dict(String, Int),
  )
}

/// High-level phase of the orchestrator.
pub type OrchestratorPhase {
  /// No graph loaded yet
  OrchestratorIdle
  /// Executing tasks
  OrchestratorRunning
  /// All tasks completed successfully
  OrchestratorDone
  /// One or more tasks permanently failed (cascades cancel dependents)
  OrchestratorFailed(reason: String)
}

/// Mutable pure state maintained by the orchestrator.
pub type OrchestratorState {
  OrchestratorState(
    /// Configuration (immutable)
    config: OrchestratorConfig,
    /// Task dependency graph with up-to-date node statuses
    graph: TaskGraph,
    /// Current execution phase
    phase: OrchestratorPhase,
    /// Task IDs currently running (sub-agent spawned)
    running: List(String),
    /// Task IDs that completed successfully
    completed: List(String),
    /// Task IDs that permanently failed (retries exhausted)
    failed: List(String),
    /// Task IDs cancelled due to a failed dependency
    cancelled: List(String),
    /// Retry attempt counts: task_id -> attempts used so far
    retry_counts: Dict(String, Int),
  )
}

/// Commands returned by pure functions for the actor to execute.
pub type OrchestratorCommand {
  /// Spawn a sub-agent to run the given task
  LaunchTask(task_id: String, task_name: String)
  /// Cancel the sub-agent currently running the given task
  CancelTask(task_id: String)
  /// Write task progress to the Blackboard
  ReportProgress(task_id: String, status: String, message: String)
}

// ============================================================================
// Constructors / Defaults
// ============================================================================

/// Create an initial idle orchestrator state.
pub fn initial_state(config: OrchestratorConfig) -> OrchestratorState {
  OrchestratorState(
    config: config,
    graph: task_graph.new(),
    phase: OrchestratorIdle,
    running: [],
    completed: [],
    failed: [],
    cancelled: [],
    retry_counts: dict.new(),
  )
}

/// Create a default configuration (no retries).
pub fn default_config(project_id: String) -> OrchestratorConfig {
  OrchestratorConfig(
    project_id: project_id,
    default_max_retries: 0,
    task_retry_overrides: dict.new(),
  )
}
