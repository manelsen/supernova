//// Budget Policy — Pure Functions
////
//// Pure functions for budget enforcement. No FFI, no side effects.
//// Functions take state and return new state + commands for the actor to execute.
////
//// ## Usage
////
//// ```gleam
//// let #(new_state, result, commands) = pure.check(state, "agent_1", BudgetTokens, 100, timestamp)
//// ```

import gleam/dict
import gleam/int
import gleam/option.{None, Some}
import supernova/core/budget_policy/types.{
  type AgentBudgetState, type BudgetCommand, type BudgetConfig,
  type BudgetExceeded, type BudgetPolicyState, type BudgetResource,
  AgentBudgetState, BudgetConfig, BudgetExceeded, BudgetPolicyState,
  BudgetRecursionDepth, BudgetSubAgents, BudgetTokens, BudgetToolCalls,
  EmitBudgetViolation, WindowState, WriteBudgetAudit,
}

// ============================================================================
// Public API
// ============================================================================

/// Check if a resource consumption is within budget.
///
/// Returns Ok(new_state) if within budget, Error(BudgetExceeded) if exceeded.
/// Also returns commands for the actor to execute (telemetry, audit).
/// Automatically resets time windows when they expire.
pub fn check(
  state: BudgetPolicyState,
  agent_id: String,
  resource: BudgetResource,
  amount: Int,
  timestamp: Int,
) -> #(BudgetPolicyState, Result(Nil, BudgetExceeded), List(BudgetCommand)) {
  let agent_state = get_or_create_agent_state(state, agent_id)
  let config = agent_state.config

  // Reset windows if expired
  let agent_state = reset_expired_windows(agent_state, timestamp)

  case resource {
    BudgetTokens -> check_tokens(state, agent_id, agent_state, config, amount)
    BudgetToolCalls ->
      check_tool_calls(state, agent_id, agent_state, config, amount)
    BudgetRecursionDepth ->
      check_recursion_depth(state, agent_id, agent_state, config, amount)
    BudgetSubAgents ->
      check_sub_agents(state, agent_id, agent_state, config, amount)
  }
}

/// Set a budget configuration for an agent.
///
/// Returns the updated state.
pub fn set_budget(
  state: BudgetPolicyState,
  agent_id: String,
  config: BudgetConfig,
  timestamp: Int,
) -> #(BudgetPolicyState, List(BudgetCommand)) {
  let agent_state = get_or_create_agent_state(state, agent_id)
  let new_agent_state = AgentBudgetState(..agent_state, config: config)
  let new_state =
    BudgetPolicyState(
      ..state,
      agents: dict.insert(state.agents, agent_id, new_agent_state),
    )

  let commands = [WriteBudgetAudit(agent_id, "set_budget", timestamp)]

  #(new_state, commands)
}

/// Get the budget configuration for an agent.
///
/// Returns the agent's config, or the default if not set.
pub fn get_budget(state: BudgetPolicyState, agent_id: String) -> BudgetConfig {
  case dict.get(state.agents, agent_id) {
    Ok(agent_state) -> agent_state.config
    Error(_) -> state.default_config
  }
}

/// Record consumption after a successful check.
///
/// This updates the time-windowed consumption counters.
pub fn record_consumption(
  state: BudgetPolicyState,
  agent_id: String,
  resource: BudgetResource,
  amount: Int,
  timestamp: Int,
) -> BudgetPolicyState {
  let agent_state = get_or_create_agent_state(state, agent_id)
  let agent_state = reset_expired_windows(agent_state, timestamp)

  let new_agent_state = case resource {
    BudgetTokens -> {
      let window = agent_state.token_window
      let new_window = WindowState(..window, consumed: window.consumed + amount)
      AgentBudgetState(..agent_state, token_window: new_window)
    }
    BudgetToolCalls -> {
      let window = agent_state.tool_call_window
      let new_window = WindowState(..window, consumed: window.consumed + amount)
      AgentBudgetState(..agent_state, tool_call_window: new_window)
    }
    BudgetRecursionDepth -> agent_state
    BudgetSubAgents -> agent_state
  }

  BudgetPolicyState(
    ..state,
    agents: dict.insert(state.agents, agent_id, new_agent_state),
  )
}

/// Set the parent agent for budget inheritance.
///
/// The child agent's budget is calculated as a percentage of the parent's.
pub fn set_parent(
  state: BudgetPolicyState,
  agent_id: String,
  parent_id: String,
  timestamp: Int,
) -> #(BudgetPolicyState, List(BudgetCommand)) {
  let agent_state = get_or_create_agent_state(state, agent_id)
  let parent_state = get_or_create_agent_state(state, parent_id)

  // Calculate inherited budget based on ratio
  let inherited_config =
    inherit_config(parent_state.config, state.inheritance_ratio)

  let new_agent_state =
    AgentBudgetState(
      ..agent_state,
      config: inherited_config,
      parent_id: Some(parent_id),
    )

  // Increment parent's sub-agent count
  let parent_new =
    AgentBudgetState(
      ..parent_state,
      current_sub_agents: parent_state.current_sub_agents + 1,
    )

  let new_state =
    BudgetPolicyState(
      ..state,
      agents: state.agents
        |> dict.insert(agent_id, new_agent_state)
        |> dict.insert(parent_id, parent_new),
    )

  let commands = [
    WriteBudgetAudit(agent_id, "inherit_from:" <> parent_id, timestamp),
  ]

  #(new_state, commands)
}

/// Release a sub-agent slot (decrement parent's sub-agent count).
pub fn release_sub_agent(
  state: BudgetPolicyState,
  agent_id: String,
  timestamp: Int,
) -> #(BudgetPolicyState, List(BudgetCommand)) {
  case dict.get(state.agents, agent_id) {
    Ok(agent_state) -> {
      case agent_state.parent_id {
        Some(parent_id) -> {
          case dict.get(state.agents, parent_id) {
            Ok(parent_state) -> {
              let new_count = int.max(0, parent_state.current_sub_agents - 1)
              let new_parent =
                AgentBudgetState(..parent_state, current_sub_agents: new_count)
              let new_state =
                BudgetPolicyState(
                  ..state,
                  agents: dict.insert(state.agents, parent_id, new_parent),
                )
              let commands = [
                WriteBudgetAudit(agent_id, "release_sub_agent", timestamp),
              ]
              #(new_state, commands)
            }
            Error(_) -> #(state, [])
          }
        }
        None -> #(state, [])
      }
    }
    Error(_) -> #(state, [])
  }
}

/// Reset all time windows for an agent.
pub fn reset_windows(
  state: BudgetPolicyState,
  agent_id: String,
  timestamp: Int,
) -> BudgetPolicyState {
  case dict.get(state.agents, agent_id) {
    Ok(agent_state) -> {
      let new_agent_state =
        AgentBudgetState(
          ..agent_state,
          token_window: WindowState(consumed: 0, window_start: timestamp),
          tool_call_window: WindowState(consumed: 0, window_start: timestamp),
        )
      BudgetPolicyState(
        ..state,
        agents: dict.insert(state.agents, agent_id, new_agent_state),
      )
    }
    Error(_) -> state
  }
}

/// Get current consumption for a resource type.
pub fn get_consumption(
  state: BudgetPolicyState,
  agent_id: String,
  resource: BudgetResource,
  timestamp: Int,
) -> Int {
  case dict.get(state.agents, agent_id) {
    Ok(agent_state) -> {
      let agent_state = reset_expired_windows(agent_state, timestamp)
      case resource {
        BudgetTokens -> agent_state.token_window.consumed
        BudgetToolCalls -> agent_state.tool_call_window.consumed
        BudgetRecursionDepth -> agent_state.current_recursion_depth
        BudgetSubAgents -> agent_state.current_sub_agents
      }
    }
    Error(_) -> 0
  }
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Get or create agent state with default config.
fn get_or_create_agent_state(
  state: BudgetPolicyState,
  agent_id: String,
) -> AgentBudgetState {
  case dict.get(state.agents, agent_id) {
    Ok(existing) -> existing
    Error(_) ->
      AgentBudgetState(
        config: state.default_config,
        token_window: WindowState(consumed: 0, window_start: 0),
        tool_call_window: WindowState(consumed: 0, window_start: 0),
        current_recursion_depth: 0,
        current_sub_agents: 0,
        parent_id: None,
      )
  }
}

/// Reset time windows if they have expired.
fn reset_expired_windows(
  agent_state: AgentBudgetState,
  timestamp: Int,
) -> AgentBudgetState {
  // Token window: 1 hour = 3_600_000 ms
  let token_window = case
    timestamp - agent_state.token_window.window_start >= 3_600_000
  {
    True -> WindowState(consumed: 0, window_start: timestamp)
    False -> agent_state.token_window
  }

  // Tool call window: 1 minute = 60_000 ms
  let tool_call_window = case
    timestamp - agent_state.tool_call_window.window_start >= 60_000
  {
    True -> WindowState(consumed: 0, window_start: timestamp)
    False -> agent_state.tool_call_window
  }

  AgentBudgetState(
    ..agent_state,
    token_window: token_window,
    tool_call_window: tool_call_window,
  )
}

/// Check token budget.
fn check_tokens(
  state: BudgetPolicyState,
  agent_id: String,
  agent_state: AgentBudgetState,
  config: BudgetConfig,
  amount: Int,
) -> #(BudgetPolicyState, Result(Nil, BudgetExceeded), List(BudgetCommand)) {
  let limit = config.tokens_per_hour
  case limit {
    -1 -> {
      // Unlimited
      let new_state =
        BudgetPolicyState(
          ..state,
          agents: dict.insert(state.agents, agent_id, agent_state),
        )
      #(new_state, Ok(Nil), [])
    }
    _ -> {
      let current = agent_state.token_window.consumed
      let new_total = current + amount
      case new_total > limit {
        True -> {
          let error =
            BudgetExceeded(
              agent_id: agent_id,
              resource: "tokens_per_hour",
              current: new_total,
              limit: limit,
              message: "Budget exceeded: agent '"
                <> agent_id
                <> "' would use "
                <> int.to_string(new_total)
                <> " tokens (limit: "
                <> int.to_string(limit)
                <> " per hour)",
            )
          let commands = [
            EmitBudgetViolation(agent_id, "tokens_per_hour", new_total, limit),
          ]
          let new_state =
            BudgetPolicyState(
              ..state,
              agents: dict.insert(state.agents, agent_id, agent_state),
            )
          #(new_state, Error(error), commands)
        }
        False -> {
          let new_state =
            BudgetPolicyState(
              ..state,
              agents: dict.insert(state.agents, agent_id, agent_state),
            )
          #(new_state, Ok(Nil), [])
        }
      }
    }
  }
}

/// Check tool call budget.
fn check_tool_calls(
  state: BudgetPolicyState,
  agent_id: String,
  agent_state: AgentBudgetState,
  config: BudgetConfig,
  amount: Int,
) -> #(BudgetPolicyState, Result(Nil, BudgetExceeded), List(BudgetCommand)) {
  let limit = config.tool_calls_per_minute
  case limit {
    -1 -> {
      let new_state =
        BudgetPolicyState(
          ..state,
          agents: dict.insert(state.agents, agent_id, agent_state),
        )
      #(new_state, Ok(Nil), [])
    }
    _ -> {
      let current = agent_state.tool_call_window.consumed
      let new_total = current + amount
      case new_total > limit {
        True -> {
          let error =
            BudgetExceeded(
              agent_id: agent_id,
              resource: "tool_calls_per_minute",
              current: new_total,
              limit: limit,
              message: "Budget exceeded: agent '"
                <> agent_id
                <> "' would make "
                <> int.to_string(new_total)
                <> " tool calls (limit: "
                <> int.to_string(limit)
                <> " per minute)",
            )
          let commands = [
            EmitBudgetViolation(
              agent_id,
              "tool_calls_per_minute",
              new_total,
              limit,
            ),
          ]
          let new_state =
            BudgetPolicyState(
              ..state,
              agents: dict.insert(state.agents, agent_id, agent_state),
            )
          #(new_state, Error(error), commands)
        }
        False -> {
          let new_state =
            BudgetPolicyState(
              ..state,
              agents: dict.insert(state.agents, agent_id, agent_state),
            )
          #(new_state, Ok(Nil), [])
        }
      }
    }
  }
}

/// Check recursion depth budget.
fn check_recursion_depth(
  state: BudgetPolicyState,
  agent_id: String,
  agent_state: AgentBudgetState,
  config: BudgetConfig,
  amount: Int,
) -> #(BudgetPolicyState, Result(Nil, BudgetExceeded), List(BudgetCommand)) {
  let limit = config.max_recursion_depth
  let current = agent_state.current_recursion_depth
  let new_depth = current + amount
  case new_depth > limit {
    True -> {
      let error =
        BudgetExceeded(
          agent_id: agent_id,
          resource: "max_recursion_depth",
          current: new_depth,
          limit: limit,
          message: "Budget exceeded: agent '"
            <> agent_id
            <> "' recursion depth "
            <> int.to_string(new_depth)
            <> " exceeds limit "
            <> int.to_string(limit),
        )
      let commands = [
        EmitBudgetViolation(agent_id, "max_recursion_depth", new_depth, limit),
      ]
      let new_state =
        BudgetPolicyState(
          ..state,
          agents: dict.insert(state.agents, agent_id, agent_state),
        )
      #(new_state, Error(error), commands)
    }
    False -> {
      let new_state =
        BudgetPolicyState(
          ..state,
          agents: dict.insert(state.agents, agent_id, agent_state),
        )
      #(new_state, Ok(Nil), [])
    }
  }
}

/// Check sub-agent count budget.
fn check_sub_agents(
  state: BudgetPolicyState,
  agent_id: String,
  agent_state: AgentBudgetState,
  config: BudgetConfig,
  amount: Int,
) -> #(BudgetPolicyState, Result(Nil, BudgetExceeded), List(BudgetCommand)) {
  let limit = config.max_sub_agents
  case limit {
    -1 -> {
      let new_state =
        BudgetPolicyState(
          ..state,
          agents: dict.insert(state.agents, agent_id, agent_state),
        )
      #(new_state, Ok(Nil), [])
    }
    _ -> {
      let current = agent_state.current_sub_agents
      let new_total = current + amount
      case new_total > limit {
        True -> {
          let error =
            BudgetExceeded(
              agent_id: agent_id,
              resource: "max_sub_agents",
              current: new_total,
              limit: limit,
              message: "Budget exceeded: agent '"
                <> agent_id
                <> "' would have "
                <> int.to_string(new_total)
                <> " sub-agents (limit: "
                <> int.to_string(limit)
                <> ")",
            )
          let commands = [
            EmitBudgetViolation(agent_id, "max_sub_agents", new_total, limit),
          ]
          let new_state =
            BudgetPolicyState(
              ..state,
              agents: dict.insert(state.agents, agent_id, agent_state),
            )
          #(new_state, Error(error), commands)
        }
        False -> {
          let new_state =
            BudgetPolicyState(
              ..state,
              agents: dict.insert(state.agents, agent_id, agent_state),
            )
          #(new_state, Ok(Nil), [])
        }
      }
    }
  }
}

/// Calculate inherited config from parent with ratio reduction.
fn inherit_config(parent_config: BudgetConfig, ratio: Int) -> BudgetConfig {
  let apply_ratio = fn(value: Int) -> Int {
    case value {
      -1 -> -1
      _ -> value * ratio / 100
    }
  }

  BudgetConfig(
    tokens_per_hour: apply_ratio(parent_config.tokens_per_hour),
    tool_calls_per_minute: apply_ratio(parent_config.tool_calls_per_minute),
    max_recursion_depth: parent_config.max_recursion_depth,
    max_sub_agents: apply_ratio(parent_config.max_sub_agents),
  )
}
