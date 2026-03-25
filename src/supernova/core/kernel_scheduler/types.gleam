//// Kernel Scheduler — Pure Types
////
//// Pure data structures for the central agent scheduler.
//// No FFI, no side effects.
//// These types define the domain model for fair scheduling across agents.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}

// ============================================================================
// Types
// ============================================================================

/// Status of a registered agent.
pub type AgentStatus {
  /// Agent is idle and ready to receive work
  Idle
  /// Agent is currently running
  Running
  /// Agent has been starved (no CPU time for too long)
  Starved
  /// Agent has exhausted its budget
  Exhausted
}

/// Priority levels for scheduling weight.
pub type SchedulerPriority {
  Critical
  High
  Normal
  Low
}

/// Information about a registered agent.
pub type AgentInfo {
  AgentInfo(
    /// Unique agent identifier
    agent_id: String,
    /// Process subject to send ticks to
    subject: Subject(Nil),
    /// Current agent status
    status: AgentStatus,
    /// Scheduling priority
    priority: SchedulerPriority,
    /// Timestamp of last tick sent (ms). 0 = never run.
    last_run: Int,
    /// Remaining budget (ticks). -1 = unlimited.
    budget_remaining: Int,
  )
}

/// Options for agent registration.
pub type SchedulerOpts {
  SchedulerOpts(
    /// Process subject to receive :scheduler_tick messages
    subject: Subject(Nil),
    /// Initial priority level
    priority: SchedulerPriority,
    /// Tick budget. -1 means unlimited.
    budget: Int,
  )
}

/// Command pattern for I/O operations.
/// Pure functions return commands; the actor executes them.
pub type SchedulerCommand {
  /// Emit telemetry when an agent is starved
  EmitStarvationTelemetry(
    agent_id: String,
    old_priority: String,
    new_priority: String,
  )
  /// Emit telemetry when agent budget is exhausted
  EmitBudgetExhaustedTelemetry(agent_id: String)
  /// Write audit log for scheduler action
  WriteSchedulerAudit(action: String, agent_id: String, timestamp: Int)
}

/// The kernel scheduler state maintained by the actor.
pub type KernelSchedulerState {
  KernelSchedulerState(
    /// Registered agents indexed by agent_id
    agents: Dict(String, AgentInfo),
    /// Round-robin cursor position
    cursor: Int,
    /// Starvation threshold in milliseconds
    starvation_threshold: Int,
    /// Tick interval in milliseconds
    tick_interval: Int,
  )
}

// ============================================================================
// Default Values
// ============================================================================

/// Create an initial empty scheduler state.
pub fn initial_state() -> KernelSchedulerState {
  KernelSchedulerState(
    agents: dict.new(),
    cursor: 0,
    starvation_threshold: 30_000,
    tick_interval: 1000,
  )
}

/// Get the numeric weight for a priority level.
/// Higher weight = more scheduling shares.
pub fn priority_weight(priority: SchedulerPriority) -> Int {
  case priority {
    Critical -> 4
    High -> 3
    Normal -> 2
    Low -> 1
  }
}

/// Convert priority to string for telemetry/audit.
pub fn priority_to_string(priority: SchedulerPriority) -> String {
  case priority {
    Critical -> "critical"
    High -> "high"
    Normal -> "normal"
    Low -> "low"
  }
}
