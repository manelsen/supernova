//// Tests for the Budget Policy Actor module
////
//// Integration tests — with actors, with I/O.

import gleam/erlang/process
import gleeunit
import gleeunit/should
import supernova/core/budget_policy/actor
import supernova/core/budget_policy/types.{
  BudgetExceeded, BudgetSubAgents, BudgetTokens, BudgetToolCalls,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Actor Lifecycle Tests
// ============================================================================

pub fn start_and_stop_test() {
  let assert Ok(policy) = actor.start()
  actor.stop(policy)

  // Give actor time to terminate
  process.sleep(100)
}

// ============================================================================
// check Tests
// ============================================================================

pub fn check_within_budget_test() {
  let assert Ok(policy) = actor.start()

  actor.check(policy, "agent_1", BudgetTokens, 500)
  |> should.be_ok()

  actor.stop(policy)
  process.sleep(100)
}

pub fn check_exceeds_budget_test() {
  let assert Ok(policy) = actor.start()

  // Record consumption near the limit
  actor.record_consumption(policy, "agent_1", BudgetTokens, 99_900)

  // Now check with amount that exceeds
  case actor.check(policy, "agent_1", BudgetTokens, 200) {
    Error(BudgetExceeded(agent_id, resource, _current, _limit, _message)) -> {
      agent_id
      |> should.equal("agent_1")
      resource
      |> should.equal("tokens_per_hour")
    }
    Ok(_) -> should.fail()
  }

  actor.stop(policy)
  process.sleep(100)
}

pub fn check_tool_calls_within_budget_test() {
  let assert Ok(policy) = actor.start()

  actor.check(policy, "agent_1", BudgetToolCalls, 30)
  |> should.be_ok()

  actor.stop(policy)
  process.sleep(100)
}

// ============================================================================
// set_budget / get_budget Tests
// ============================================================================

pub fn set_and_get_budget_test() {
  let assert Ok(policy) = actor.start()

  let config =
    types.BudgetConfig(
      tokens_per_hour: 50_000,
      tool_calls_per_minute: 30,
      tool_calls_per_hour: -1,
      max_recursion_depth: 3,
      max_sub_agents: 5,
    )

  actor.set_budget(policy, "agent_1", config)

  let retrieved = actor.get_budget(policy, "agent_1")
  retrieved.tokens_per_hour
  |> should.equal(50_000)
  retrieved.tool_calls_per_minute
  |> should.equal(30)

  actor.stop(policy)
  process.sleep(100)
}

pub fn get_budget_returns_default_for_unknown_test() {
  let assert Ok(policy) = actor.start()

  let config = actor.get_budget(policy, "unknown_agent")
  config.tokens_per_hour
  |> should.equal(100_000)

  actor.stop(policy)
  process.sleep(100)
}

// ============================================================================
// record_consumption Tests
// ============================================================================

pub fn record_consumption_tracks_usage_test() {
  let assert Ok(policy) = actor.start()

  actor.record_consumption(policy, "agent_1", BudgetTokens, 500)

  let consumption = actor.get_consumption(policy, "agent_1", BudgetTokens)
  consumption
  |> should.equal(500)

  actor.stop(policy)
  process.sleep(100)
}

pub fn record_consumption_accumulates_test() {
  let assert Ok(policy) = actor.start()

  actor.record_consumption(policy, "agent_1", BudgetTokens, 100)
  actor.record_consumption(policy, "agent_1", BudgetTokens, 200)

  let consumption = actor.get_consumption(policy, "agent_1", BudgetTokens)
  consumption
  |> should.equal(300)

  actor.stop(policy)
  process.sleep(100)
}

// ============================================================================
// set_parent Tests — Sub-Agent Inheritance
// ============================================================================

pub fn set_parent_inherits_budget_test() {
  let assert Ok(policy) = actor.start()

  // Set parent budget
  let parent_config =
    types.BudgetConfig(
      tokens_per_hour: 100_000,
      tool_calls_per_minute: 100,
      tool_calls_per_hour: -1,
      max_recursion_depth: 5,
      max_sub_agents: 10,
    )
  actor.set_budget(policy, "parent", parent_config)

  // Create child with inheritance
  actor.set_parent(policy, "child", "parent")

  // Check child's budget (should be 20% of parent)
  let child_config = actor.get_budget(policy, "child")
  child_config.tokens_per_hour
  |> should.equal(20_000)
  child_config.tool_calls_per_minute
  |> should.equal(20)

  actor.stop(policy)
  process.sleep(100)
}

pub fn parent_sub_agent_count_test() {
  let assert Ok(policy) = actor.start()

  // Create children
  actor.set_parent(policy, "child_1", "parent")
  actor.set_parent(policy, "child_2", "parent")

  // Check parent's sub-agent count
  let count = actor.get_consumption(policy, "parent", BudgetSubAgents)
  count
  |> should.equal(2)

  actor.stop(policy)
  process.sleep(100)
}

// ============================================================================
// release_sub_agent Tests
// ============================================================================

pub fn release_sub_agent_decrements_count_test() {
  let assert Ok(policy) = actor.start()

  // Create children
  actor.set_parent(policy, "child_1", "parent")
  actor.set_parent(policy, "child_2", "parent")

  // Release one
  actor.release_sub_agent(policy, "child_1")

  // Check parent's sub-agent count
  let count = actor.get_consumption(policy, "parent", BudgetSubAgents)
  count
  |> should.equal(1)

  actor.stop(policy)
  process.sleep(100)
}

// ============================================================================
// reset_windows Tests
// ============================================================================

pub fn reset_windows_clears_consumption_test() {
  let assert Ok(policy) = actor.start()

  // Record consumption
  actor.record_consumption(policy, "agent_1", BudgetTokens, 500)

  // Verify
  let consumption = actor.get_consumption(policy, "agent_1", BudgetTokens)
  consumption
  |> should.equal(500)

  // Reset
  actor.reset_windows(policy, "agent_1")

  // Verify cleared
  let consumption = actor.get_consumption(policy, "agent_1", BudgetTokens)
  consumption
  |> should.equal(0)

  actor.stop(policy)
  process.sleep(100)
}

// ============================================================================
// start_with_config Tests
// ============================================================================

pub fn start_with_custom_config_test() {
  let custom_default =
    types.BudgetConfig(
      tokens_per_hour: 50_000,
      tool_calls_per_minute: 30,
      tool_calls_per_hour: -1,
      max_recursion_depth: 3,
      max_sub_agents: 5,
    )

  let assert Ok(policy) = actor.start_with_config(custom_default, 25)

  // Check that default is applied
  let config = actor.get_budget(policy, "any_agent")
  config.tokens_per_hour
  |> should.equal(50_000)

  actor.stop(policy)
  process.sleep(100)
}
