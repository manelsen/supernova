//// Tests for the Sub-Agent module

import gleam/dynamic/decode
import gleeunit
import supernova/core/sub_agent

pub fn main() -> Nil {
  gleeunit.main()
}

// Test: Sub-agent can be spawned with default config
pub fn spawn_agent_test() {
  let config = sub_agent.default_config()
  let assert Ok(agent) = sub_agent.spawn("parent-001", "Test goal", config)

  // Verify the agent is running by getting its status
  let status = sub_agent.get_status(agent)
  // Status should be completed (goal executes immediately in mock)
  assert status == sub_agent.SubAgentCompleted

  // Clean up
  sub_agent.stop(agent)
}

// Test: Sub-agent can be spawned with custom timeout config
pub fn spawn_with_timeout_test() {
  let config = sub_agent.config_with_timeout(10_000)
  let assert Ok(agent) = sub_agent.spawn("parent-002", "Quick task", config)

  // Verify the agent completed
  let result = sub_agent.get_result(agent)
  assert result.agent_id != ""
  assert result.status == sub_agent.ResultSuccess

  // Clean up
  sub_agent.stop(agent)
}

// Test: Sub-agent can be spawned with custom depth config
pub fn spawn_with_depth_test() {
  let config = sub_agent.config_with_depth(3, 1)
  let assert Ok(agent) = sub_agent.spawn("parent-003", "Nested task", config)

  // Verify the agent completed
  let status = sub_agent.get_status(agent)
  assert status == sub_agent.SubAgentCompleted

  // Clean up
  sub_agent.stop(agent)
}

// Test: Sub-agent executes goal and produces typed output
pub fn execute_goal_test() {
  let config = sub_agent.default_config()
  let assert Ok(agent) = sub_agent.spawn("parent-004", "Analyze code", config)

  // Get the result
  let result = sub_agent.get_result(agent)

  // Verify result structure
  assert result.status == sub_agent.ResultSuccess

  // Verify output is accessible as dynamic string
  let assert Ok(output) = decode.run(result.output, decode.string)
  assert output == "Goal 'Analyze code' completed by agent " <> result.agent_id

  // Clean up
  sub_agent.stop(agent)
}

// Test: Sub-agent can be cancelled
pub fn cancel_agent_test() {
  let config = sub_agent.default_config()
  let assert Ok(agent) = sub_agent.spawn("parent-005", "Long task", config)

  // Cancel the agent
  let result = sub_agent.cancel(agent)
  assert result == Ok(Nil)

  // Verify status is cancelled
  let status = sub_agent.get_status(agent)
  assert status == sub_agent.SubAgentCancelled

  // Clean up
  sub_agent.stop(agent)
}

// Test: Sub-agent await returns result
pub fn await_result_test() {
  let config = sub_agent.default_config()
  let assert Ok(agent) = sub_agent.spawn("parent-006", "Awaited task", config)

  // Await the result
  let assert Ok(result) = sub_agent.await(agent, 5000)

  // Verify result
  assert result.status == sub_agent.ResultSuccess
  assert result.agent_id != ""

  // Clean up
  sub_agent.stop(agent)
}

// Test: Sub-agent await with timeout
pub fn await_timeout_test() {
  let config = sub_agent.config_with_timeout(100)
  let assert Ok(agent) = sub_agent.spawn("parent-007", "Timeout task", config)

  // Await with a very short timeout
  let result = sub_agent.await(agent, 50)

  // Should succeed since mock execution is instant
  let assert Ok(result) = result
  assert result.agent_id != ""

  // Clean up
  sub_agent.stop(agent)
}

// Test: Sub-agent respects max depth limit
pub fn max_depth_test() {
  let config = sub_agent.config_with_depth(1, 1)
  let assert Ok(agent) = sub_agent.spawn("parent-008", "Deep task", config)

  // Get the result - should fail due to depth limit
  let result = sub_agent.get_result(agent)

  // Verify the agent failed due to depth
  assert result.status == sub_agent.ResultFailure

  // Clean up
  sub_agent.stop(agent)
}

// Test: Sub-agent result has correct structure (US-018)
pub fn result_structure_test() {
  let config = sub_agent.default_config()
  let assert Ok(agent) = sub_agent.spawn("parent-009", "Structure test", config)

  // Get the result
  let result = sub_agent.get_result(agent)

  // Verify all US-018 fields are present
  assert result.agent_id != ""
  assert result.status == sub_agent.ResultSuccess
  assert result.tokens_used > 0
  assert result.duration_ms >= 0

  // Clean up
  sub_agent.stop(agent)
}

// Test: Multiple sub-agents can be spawned
pub fn multiple_agents_test() {
  let config = sub_agent.default_config()

  // Spawn multiple agents
  let assert Ok(agent1) = sub_agent.spawn("parent-010", "Task 1", config)
  let assert Ok(agent2) = sub_agent.spawn("parent-010", "Task 2", config)
  let assert Ok(agent3) = sub_agent.spawn("parent-010", "Task 3", config)

  // Verify all completed with ResultSuccess
  assert sub_agent.get_result(agent1).status == sub_agent.ResultSuccess
  assert sub_agent.get_result(agent2).status == sub_agent.ResultSuccess
  assert sub_agent.get_result(agent3).status == sub_agent.ResultSuccess

  // Clean up
  sub_agent.stop(agent1)
  sub_agent.stop(agent2)
  sub_agent.stop(agent3)
}

// Test: Sub-agent can be stopped gracefully
pub fn stop_agent_test() {
  let config = sub_agent.default_config()
  let assert Ok(agent) = sub_agent.spawn("parent-011", "Stop test", config)

  // Stop the agent - should not crash
  sub_agent.stop(agent)
}

// Test: Sub-agent IDs are unique
pub fn unique_ids_test() {
  let config = sub_agent.default_config()

  // Spawn two agents with same parent
  let assert Ok(agent1) = sub_agent.spawn("parent-012", "Task A", config)
  let assert Ok(agent2) = sub_agent.spawn("parent-012", "Task B", config)

  // Get results
  let result1 = sub_agent.get_result(agent1)
  let result2 = sub_agent.get_result(agent2)

  // Verify IDs are different
  assert result1.agent_id != result2.agent_id

  // Clean up
  sub_agent.stop(agent1)
  sub_agent.stop(agent2)
}
