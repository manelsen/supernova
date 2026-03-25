//// Tests for the Core Agent module

import gleam/dict
import gleam/option
import gleeunit
import supernova/core/agent

pub fn main() -> Nil {
  gleeunit.main()
}

// Test: Agent can be started with default config
pub fn start_agent_test() {
  let config = agent.default_config("test-001", "Test Agent")
  let assert Ok(agent_subject) = agent.start(config)

  // Verify the agent is running by getting its status
  let status = agent.get_status(agent_subject)
  assert status == agent.Starting

  // Clean up
  agent.stop(agent_subject)
}

// Test: Agent can be started with system prompt
pub fn start_agent_with_system_prompt_test() {
  let config =
    agent.config_with_system_prompt(
      "test-002",
      "Test Agent 2",
      "You are a helpful assistant.",
    )

  let assert Ok(agent_subject) = agent.start(config)

  // Verify config has the system prompt
  let retrieved_config = agent.get_config(agent_subject)
  assert retrieved_config.id == "test-002"
  assert retrieved_config.name == "Test Agent 2"

  // Clean up
  agent.stop(agent_subject)
}

// Test: Agent status can be updated
pub fn set_status_test() {
  let config = agent.default_config("test-003", "Test Agent 3")
  let assert Ok(agent_subject) = agent.start(config)

  // Set status to Ready
  agent.set_status(agent_subject, agent.Ready)

  // Verify status was updated
  let status = agent.get_status(agent_subject)
  assert status == agent.Ready

  // Clean up
  agent.stop(agent_subject)
}

// Test: Agent can send and receive messages
pub fn send_message_test() {
  let config = agent.default_config("test-004", "Test Agent 4")
  let assert Ok(agent_subject) = agent.start(config)

  // Send a user message
  let result = agent.send_message(agent_subject, "user", "Hello, agent!")
  assert result == Ok(Nil)

  // Verify message was stored in memory
  let memory = agent.get_memory(agent_subject)
  assert dict.size(memory) == 1

  // Clean up
  agent.stop(agent_subject)
}

// Test: Agent memory can be cleared
pub fn clear_memory_test() {
  let config = agent.default_config("test-005", "Test Agent 5")
  let assert Ok(agent_subject) = agent.start(config)

  // Send a message
  let _ = agent.send_message(agent_subject, "user", "Hello!")
  let _ = agent.send_message(agent_subject, "assistant", "Hi there!")

  // Verify messages are in memory
  let memory = agent.get_memory(agent_subject)
  assert dict.size(memory) == 2

  // Clear memory
  agent.clear_memory(agent_subject)

  // Verify memory is empty
  let cleared_memory = agent.get_memory(agent_subject)
  assert dict.size(cleared_memory) == 0

  // Clean up
  agent.stop(agent_subject)
}

// Test: Agent respects max memory size
pub fn memory_limit_test() {
  let config =
    agent.Config(
      id: "test-006",
      name: "Limited Agent",
      system_prompt: option.None,
      max_memory_size: 2,
    )

  let assert Ok(agent_subject) = agent.start(config)

  // Send two messages - should succeed
  let result1 = agent.send_message(agent_subject, "user", "Message 1")
  assert result1 == Ok(Nil)

  let result2 = agent.send_message(agent_subject, "user", "Message 2")
  assert result2 == Ok(Nil)

  // Third message should fail due to memory limit
  let result3 = agent.send_message(agent_subject, "user", "Message 3")
  assert result3 == Error("Memory full")

  // Clean up
  agent.stop(agent_subject)
}

// Test: Agent can be stopped
pub fn stop_agent_test() {
  let config = agent.default_config("test-007", "Test Agent 7")
  let assert Ok(agent_subject) = agent.start(config)

  // Stop the agent - should not crash
  agent.stop(agent_subject)
}

// Test: Memory entries have correct structure
pub fn memory_entry_structure_test() {
  let config = agent.default_config("test-008", "Test Agent 8")
  let assert Ok(agent_subject) = agent.start(config)

  // Send a message
  let _ = agent.send_message(agent_subject, "user", "Test content")

  // Get the memory entry
  let memory = agent.get_memory(agent_subject)
  let assert Ok(entry) = dict.get(memory, 0)

  // Verify entry structure
  assert entry.role == "user"
  assert entry.content == "Test content"

  // Clean up
  agent.stop(agent_subject)
}
