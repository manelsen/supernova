//// Budget Policy — Pure Types
////
//// Pure data structures for configurable resource limits per agent.
//// No FFI, no side effects.
//// These types define the domain model for budget enforcement.

import gleam/dict.{type Dict}
import gleam/option.{type Option}

// ============================================================================
// Types
// ============================================================================
// BudgetConfig — Resource limits per agent

/// Configurable resource limits for an agent.
pub type BudgetConfig {
  BudgetConfig(
    /// Maximum LLM tokens per hour (-1 = unlimited)
    tokens_per_hour: Int,
    /// Maximum tool calls per minute (-1 = unlimited)
    tool_calls_per_minute: Int,
    /// Maximum recursion depth for sub-agents
    max_recursion_depth: Int,
    /// Maximum number of concurrent sub-agents
    max_sub_agents: Int,
  )
}

/// Types of resources that can be budget-checked.
pub type BudgetResource {
  /// LLM token consumption (prompt + completion)
  BudgetTokens
  /// Tool call consumption (any tool)
  BudgetToolCalls
  /// Recursion depth for sub-agents
  BudgetRecursionDepth
  /// Number of concurrent sub-agents
  BudgetSubAgents
}

/// Error when a budget limit is exceeded.
pub type BudgetExceeded {
  BudgetExceeded(
    /// Agent that exceeded the budget
    agent_id: String,
    /// Resource type that was exceeded
    resource: String,
    /// Current consumption
    current: Int,
    /// Configured limit
    limit: Int,
    /// Human-readable message
    message: String,
  )
}

/// Command pattern for I/O operations.
/// Pure functions return commands; the actor executes them.
pub type BudgetCommand {
  /// Emit a telemetry event for budget violation
  EmitBudgetViolation(
    agent_id: String,
    resource: String,
    current: Int,
    limit: Int,
  )
  /// Write audit log for budget change
  WriteBudgetAudit(agent_id: String, action: String, timestamp: Int)
}

/// Window state for time-based tracking.
pub type WindowState {
  WindowState(
    /// Current consumption in this window
    consumed: Int,
    /// Timestamp when this window started (ms)
    window_start: Int,
  )
}

/// Per-agent budget tracking state.
pub type AgentBudgetState {
  AgentBudgetState(
    /// The budget config for this agent
    config: BudgetConfig,
    /// Token consumption window (hourly)
    token_window: WindowState,
    /// Tool call consumption window (per minute)
    tool_call_window: WindowState,
    /// Current recursion depth
    current_recursion_depth: Int,
    /// Current number of active sub-agents
    current_sub_agents: Int,
    /// Parent agent ID (for inheritance)
    parent_id: Option(String),
  )
}

/// The budget policy state maintained by the actor.
pub type BudgetPolicyState {
  BudgetPolicyState(
    /// Per-agent budget states
    agents: Dict(String, AgentBudgetState),
    /// Default budget config for agents without explicit config
    default_config: BudgetConfig,
    /// Inheritance ratio for sub-agents (e.g., 20 = 20% of parent)
    inheritance_ratio: Int,
  )
}

// ============================================================================
// Default Values
// ============================================================================

/// Create a default budget configuration.
pub fn default_budget_config() -> BudgetConfig {
  BudgetConfig(
    tokens_per_hour: 100_000,
    tool_calls_per_minute: 60,
    max_recursion_depth: 5,
    max_sub_agents: 10,
  )
}

/// Create an unlimited budget configuration.
pub fn unlimited_budget_config() -> BudgetConfig {
  BudgetConfig(
    tokens_per_hour: -1,
    tool_calls_per_minute: -1,
    max_recursion_depth: 5,
    max_sub_agents: -1,
  )
}
