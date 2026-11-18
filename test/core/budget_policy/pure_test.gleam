//// Tests for the Budget Policy Pure module
////
//// Pure tests — no I/O, no actors, no FFI.

import gleam/dict
import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/budget_policy/pure
import supernova/core/budget_policy/types.{
  type BudgetPolicyState, BudgetConfig, BudgetExceeded, BudgetPolicyState,
  BudgetRecursionDepth, BudgetSubAgents, BudgetTokens, BudgetToolCalls,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helpers
// ============================================================================

fn empty_state() -> BudgetPolicyState {
  BudgetPolicyState(
    agents: dict.new(),
    default_config: types.default_budget_config(),
    inheritance_ratio: 20,
  )
}

fn custom_config(t: Int, tc: Int, rd: Int, sa: Int) -> types.BudgetConfig {
  BudgetConfig(
    tokens_per_hour: t,
    tool_calls_per_minute: tc,
    tool_calls_per_hour: -1,
    max_recursion_depth: rd,
    max_sub_agents: sa,
  )
}

// ============================================================================
// check Tests — Limit Respected
// ============================================================================

pub fn check_tokens_within_budget_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, _commands) =
    pure.check(state, "agent_1", BudgetTokens, 500, timestamp)

  result
  |> should.be_ok()
}

pub fn check_tool_calls_within_budget_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, _commands) =
    pure.check(state, "agent_1", BudgetToolCalls, 30, timestamp)

  result
  |> should.be_ok()
}

pub fn check_recursion_depth_within_budget_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, _commands) =
    pure.check(state, "agent_1", BudgetRecursionDepth, 3, timestamp)

  result
  |> should.be_ok()
}

pub fn check_sub_agents_within_budget_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, _commands) =
    pure.check(state, "agent_1", BudgetSubAgents, 5, timestamp)

  result
  |> should.be_ok()
}

// ============================================================================
// check Tests — Violation Interrupts
// ============================================================================

pub fn check_tokens_exceeds_budget_test() {
  let state = empty_state()
  let timestamp = 1000

  // First consume some tokens
  let state =
    pure.record_consumption(state, "agent_1", BudgetTokens, 99_900, timestamp)

  // Now try to consume more than remaining
  let #(_state, result, commands) =
    pure.check(state, "agent_1", BudgetTokens, 200, timestamp)

  case result {
    Error(BudgetExceeded(agent_id, resource, current, limit, message)) -> {
      agent_id
      |> should.equal("agent_1")
      resource
      |> should.equal("tokens_per_hour")
      current
      |> should.equal(100_100)
      limit
      |> should.equal(100_000)
      message
      |> should.equal(
        "Budget exceeded: agent 'agent_1' would use 100100 tokens (limit: 100000 per hour)",
      )
    }
    Ok(_) -> should.fail()
  }

  // Should have emitted a violation command
  list.length(commands)
  |> should.equal(1)
}

pub fn check_tool_calls_exceeds_budget_test() {
  let state = empty_state()
  let timestamp = 1000

  // First consume some tool calls
  let state =
    pure.record_consumption(state, "agent_1", BudgetToolCalls, 55, timestamp)

  // Now try to exceed
  let #(_state, result, _commands) =
    pure.check(state, "agent_1", BudgetToolCalls, 10, timestamp)

  case result {
    Error(BudgetExceeded(agent_id, resource, current, limit, _message)) -> {
      agent_id
      |> should.equal("agent_1")
      resource
      |> should.equal("tool_calls_per_minute")
      current
      |> should.equal(65)
      limit
      |> should.equal(60)
    }
    Ok(_) -> should.fail()
  }
}

pub fn check_recursion_depth_exceeds_budget_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, _commands) =
    pure.check(state, "agent_1", BudgetRecursionDepth, 6, timestamp)

  case result {
    Error(BudgetExceeded(agent_id, resource, current, limit, _message)) -> {
      agent_id
      |> should.equal("agent_1")
      resource
      |> should.equal("max_recursion_depth")
      current
      |> should.equal(6)
      limit
      |> should.equal(5)
    }
    Ok(_) -> should.fail()
  }
}

pub fn check_sub_agents_exceeds_budget_test() {
  let state = empty_state()
  let timestamp = 1000

  // First set up some sub-agents
  let state =
    pure.record_consumption(state, "agent_1", BudgetTokens, 0, timestamp)

  // Manually set sub-agent count via set_parent
  let #(state, _commands) =
    pure.set_parent(state, "child_1", "agent_1", timestamp)
  let #(state, _commands) =
    pure.set_parent(state, "child_2", "agent_1", timestamp)

  // Now check if we can add more (default max is 10)
  let #(_state, result, _commands) =
    pure.check(state, "agent_1", BudgetSubAgents, 9, timestamp)

  case result {
    Error(BudgetExceeded(_agent_id, resource, current, limit, _message)) -> {
      resource
      |> should.equal("max_sub_agents")
      current
      |> should.equal(11)
      limit
      |> should.equal(10)
    }
    Ok(_) -> should.fail()
  }
}

pub fn check_unlimited_budget_test() {
  let state = empty_state()
  let timestamp = 1000

  // Set unlimited budget
  let config = custom_config(-1, -1, 5, -1)
  let #(state, _commands) = pure.set_budget(state, "agent_1", config, timestamp)

  // Should pass even with huge amount
  let #(_state, result, _commands) =
    pure.check(state, "agent_1", BudgetTokens, 1_000_000, timestamp)

  result
  |> should.be_ok()
}

// ============================================================================
// reset_windows Tests — Time Window Reset
// ============================================================================

pub fn reset_token_window_after_hour_test() {
  let state = empty_state()
  let timestamp = 1000

  // Consume tokens
  let state =
    pure.record_consumption(state, "agent_1", BudgetTokens, 99_900, timestamp)

  // Verify consumption
  pure.get_consumption(state, "agent_1", BudgetTokens, timestamp)
  |> should.equal(99_900)

  // Advance time by 1 hour + 1 ms
  let new_timestamp = timestamp + 3_600_001

  // Check should pass now because window was reset
  let #(_state, result, _commands) =
    pure.check(state, "agent_1", BudgetTokens, 500, new_timestamp)

  result
  |> should.be_ok()
}

pub fn reset_tool_call_window_after_minute_test() {
  let state = empty_state()
  let timestamp = 1000

  // Consume tool calls
  let state =
    pure.record_consumption(state, "agent_1", BudgetToolCalls, 55, timestamp)

  // Verify consumption
  pure.get_consumption(state, "agent_1", BudgetToolCalls, timestamp)
  |> should.equal(55)

  // Advance time by 1 minute + 1 ms
  let new_timestamp = timestamp + 60_001

  // Check should pass now because window was reset
  let #(_state, result, _commands) =
    pure.check(state, "agent_1", BudgetToolCalls, 10, new_timestamp)

  result
  |> should.be_ok()
}

pub fn window_not_reset_before_expiry_test() {
  let state = empty_state()
  let timestamp = 1000

  // Consume tokens
  let state =
    pure.record_consumption(state, "agent_1", BudgetTokens, 99_900, timestamp)

  // Advance time by only 30 minutes (not enough to reset)
  let new_timestamp = timestamp + 1_800_000

  // Check should still fail
  let #(_state, result, _commands) =
    pure.check(state, "agent_1", BudgetTokens, 200, new_timestamp)

  result
  |> should.be_error()
}

pub fn explicit_reset_windows_test() {
  let state = empty_state()
  let timestamp = 1000

  // Consume tokens
  let state =
    pure.record_consumption(state, "agent_1", BudgetTokens, 99_900, timestamp)

  // Explicitly reset windows
  let state = pure.reset_windows(state, "agent_1", timestamp)

  // Verify consumption is now 0
  pure.get_consumption(state, "agent_1", BudgetTokens, timestamp)
  |> should.equal(0)

  // Check should pass
  let #(_state, result, _commands) =
    pure.check(state, "agent_1", BudgetTokens, 500, timestamp)

  result
  |> should.be_ok()
}

// ============================================================================
// set_parent Tests — Sub-Agent Inheritance
// ============================================================================

pub fn sub_agent_inherits_reduced_budget_test() {
  let state = empty_state()
  let timestamp = 1000

  // Set parent budget
  let parent_config = custom_config(100_000, 100, 5, 10)
  let #(state, _commands) =
    pure.set_budget(state, "parent", parent_config, timestamp)

  // Create child with inheritance (default 20%)
  let #(state, _commands) = pure.set_parent(state, "child", "parent", timestamp)

  // Check child's budget
  let child_config = pure.get_budget(state, "child")

  // Should be 20% of parent
  child_config.tokens_per_hour
  |> should.equal(20_000)
  child_config.tool_calls_per_minute
  |> should.equal(20)
  // max_recursion_depth is inherited as-is
  child_config.max_recursion_depth
  |> should.equal(5)
  child_config.max_sub_agents
  |> should.equal(2)
}

pub fn sub_agent_inheritance_with_custom_ratio_test() {
  let state =
    BudgetPolicyState(
      agents: dict.new(),
      default_config: types.default_budget_config(),
      inheritance_ratio: 50,
    )
  let timestamp = 1000

  // Set parent budget
  let parent_config = custom_config(100_000, 100, 5, 10)
  let #(state, _commands) =
    pure.set_budget(state, "parent", parent_config, timestamp)

  // Create child with inheritance (50%)
  let #(state, _commands) = pure.set_parent(state, "child", "parent", timestamp)

  // Check child's budget
  let child_config = pure.get_budget(state, "child")

  // Should be 50% of parent
  child_config.tokens_per_hour
  |> should.equal(50_000)
  child_config.tool_calls_per_minute
  |> should.equal(50)
}

pub fn sub_agent_unlimited_inheritance_test() {
  let state = empty_state()
  let timestamp = 1000

  // Set parent with unlimited budget
  let parent_config = custom_config(-1, -1, 5, -1)
  let #(state, _commands) =
    pure.set_budget(state, "parent", parent_config, timestamp)

  // Create child
  let #(state, _commands) = pure.set_parent(state, "child", "parent", timestamp)

  // Check child's budget
  let child_config = pure.get_budget(state, "child")

  // Unlimited should stay unlimited
  child_config.tokens_per_hour
  |> should.equal(-1)
  child_config.tool_calls_per_minute
  |> should.equal(-1)
  child_config.max_sub_agents
  |> should.equal(-1)
}

pub fn parent_sub_agent_count_increments_test() {
  let state = empty_state()
  let timestamp = 1000

  // Create two children
  let #(state, _commands) =
    pure.set_parent(state, "child_1", "parent", timestamp)
  let #(state, _commands) =
    pure.set_parent(state, "child_2", "parent", timestamp)

  // Check parent's sub-agent count
  pure.get_consumption(state, "parent", BudgetSubAgents, timestamp)
  |> should.equal(2)
}

pub fn release_sub_agent_decrements_count_test() {
  let state = empty_state()
  let timestamp = 1000

  // Create two children
  let #(state, _commands) =
    pure.set_parent(state, "child_1", "parent", timestamp)
  let #(state, _commands) =
    pure.set_parent(state, "child_2", "parent", timestamp)

  // Release one
  let #(state, _commands) = pure.release_sub_agent(state, "child_1", timestamp)

  // Check parent's sub-agent count
  pure.get_consumption(state, "parent", BudgetSubAgents, timestamp)
  |> should.equal(1)
}

// ============================================================================
// get_budget Tests
// ============================================================================

pub fn get_budget_returns_default_for_unknown_agent_test() {
  let state = empty_state()

  let config = pure.get_budget(state, "unknown_agent")

  config.tokens_per_hour
  |> should.equal(100_000)
  config.tool_calls_per_minute
  |> should.equal(60)
}

pub fn get_budget_returns_custom_config_test() {
  let state = empty_state()
  let timestamp = 1000

  let custom = custom_config(50_000, 30, 3, 5)
  let #(state, _commands) = pure.set_budget(state, "agent_1", custom, timestamp)

  let config = pure.get_budget(state, "agent_1")

  config.tokens_per_hour
  |> should.equal(50_000)
  config.tool_calls_per_minute
  |> should.equal(30)
  config.max_recursion_depth
  |> should.equal(3)
  config.max_sub_agents
  |> should.equal(5)
}

// ============================================================================
// record_consumption Tests
// ============================================================================

pub fn record_consumption_tracks_tokens_test() {
  let state = empty_state()
  let timestamp = 1000

  let state =
    pure.record_consumption(state, "agent_1", BudgetTokens, 500, timestamp)

  pure.get_consumption(state, "agent_1", BudgetTokens, timestamp)
  |> should.equal(500)
}

pub fn record_consumption_accumulates_test() {
  let state = empty_state()
  let timestamp = 1000

  let state =
    pure.record_consumption(state, "agent_1", BudgetTokens, 100, timestamp)
  let state =
    pure.record_consumption(state, "agent_1", BudgetTokens, 200, timestamp)

  pure.get_consumption(state, "agent_1", BudgetTokens, timestamp)
  |> should.equal(300)
}

pub fn record_consumption_tracks_tool_calls_test() {
  let state = empty_state()
  let timestamp = 1000

  let state =
    pure.record_consumption(state, "agent_1", BudgetToolCalls, 10, timestamp)

  pure.get_consumption(state, "agent_1", BudgetToolCalls, timestamp)
  |> should.equal(10)
}
