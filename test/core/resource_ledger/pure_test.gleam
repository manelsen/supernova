//// Tests for the Resource Ledger Pure module
////
//// Pure tests — no I/O, no actors, no FFI.

import gleam/dict
import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/resource_ledger/pure
import supernova/core/resource_ledger/types.{
  type LedgerState, LLMTokensCompletion, LLMTokensPrompt, LedgerState,
  QuotaExceeded, StorageRead, StorageWrite, ToolCall,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helper: Create empty state
// ============================================================================

fn empty_state() -> LedgerState {
  LedgerState(counters: dict.new())
}

// ============================================================================
// charge Tests
// ============================================================================

pub fn charge_llm_tokens_prompt_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(new_state, commands) =
    pure.charge(state, "agent_1", LLMTokensPrompt, 100, timestamp)

  let assert Ok(counters) = pure.snapshot(new_state, "agent_1")
  counters.llm_tokens_prompt
  |> should.equal(100)

  list.length(commands)
  |> should.equal(2)
}

pub fn charge_llm_tokens_completion_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(new_state, commands) =
    pure.charge(state, "agent_1", LLMTokensCompletion, 50, timestamp)

  let assert Ok(counters) = pure.snapshot(new_state, "agent_1")
  counters.llm_tokens_completion
  |> should.equal(50)

  list.length(commands)
  |> should.equal(2)
}

pub fn charge_tool_call_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(new_state, _commands) =
    pure.charge(state, "agent_1", ToolCall("echo"), 1, timestamp)

  let assert Ok(counters) = pure.snapshot(new_state, "agent_1")
  let assert Ok(count) = dict.get(counters.tool_calls, "echo")
  count
  |> should.equal(1)
}

pub fn charge_tool_call_multiple_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(state1, _) =
    pure.charge(state, "agent_1", ToolCall("echo"), 1, timestamp)
  let #(state2, _) =
    pure.charge(state1, "agent_1", ToolCall("echo"), 1, timestamp)
  let #(state3, _) =
    pure.charge(state2, "agent_1", ToolCall("calc"), 1, timestamp)

  let assert Ok(counters) = pure.snapshot(state3, "agent_1")
  let assert Ok(echo_count) = dict.get(counters.tool_calls, "echo")
  let assert Ok(calc_count) = dict.get(counters.tool_calls, "calc")

  echo_count
  |> should.equal(2)
  calc_count
  |> should.equal(1)
}

pub fn charge_storage_operations_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(state1, _) = pure.charge(state, "agent_1", StorageRead, 10, timestamp)
  let #(state2, _) = pure.charge(state1, "agent_1", StorageWrite, 5, timestamp)

  let assert Ok(counters) = pure.snapshot(state2, "agent_1")
  counters.storage_reads
  |> should.equal(10)
  counters.storage_writes
  |> should.equal(5)
}

pub fn charge_accumulates_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(state1, _) =
    pure.charge(state, "agent_1", LLMTokensPrompt, 100, timestamp)
  let #(state2, _) =
    pure.charge(state1, "agent_1", LLMTokensPrompt, 50, timestamp)

  let assert Ok(counters) = pure.snapshot(state2, "agent_1")
  counters.llm_tokens_prompt
  |> should.equal(150)
}

pub fn charge_multiple_agents_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(state1, _) =
    pure.charge(state, "agent_1", LLMTokensPrompt, 100, timestamp)
  let #(state2, _) =
    pure.charge(state1, "agent_2", LLMTokensPrompt, 200, timestamp)

  let assert Ok(counters1) = pure.snapshot(state2, "agent_1")
  let assert Ok(counters2) = pure.snapshot(state2, "agent_2")

  counters1.llm_tokens_prompt
  |> should.equal(100)
  counters2.llm_tokens_prompt
  |> should.equal(200)
}

// ============================================================================
// snapshot Tests
// ============================================================================

pub fn snapshot_returns_counters_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(new_state, _) =
    pure.charge(state, "agent_1", LLMTokensPrompt, 100, timestamp)

  let assert Ok(counters) = pure.snapshot(new_state, "agent_1")
  counters.llm_tokens_prompt
  |> should.equal(100)
}

pub fn snapshot_agent_not_found_test() {
  let state = empty_state()

  pure.snapshot(state, "nonexistent")
  |> should.be_error()
}

// ============================================================================
// quota_exceeded Tests
// ============================================================================

pub fn quota_exceeded_under_limit_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(new_state, _) =
    pure.charge(state, "agent_1", LLMTokensPrompt, 100, timestamp)

  pure.quota_exceeded(new_state, "agent_1", LLMTokensPrompt, 200)
  |> should.be_ok()
}

pub fn quota_exceeded_at_limit_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(new_state, _) =
    pure.charge(state, "agent_1", LLMTokensPrompt, 100, timestamp)

  case pure.quota_exceeded(new_state, "agent_1", LLMTokensPrompt, 100) {
    Error(QuotaExceeded(agent_id, resource, current, limit)) -> {
      agent_id
      |> should.equal("agent_1")
      resource
      |> should.equal("llm_tokens_prompt")
      current
      |> should.equal(100)
      limit
      |> should.equal(100)
    }
    Ok(_) -> should.fail()
    _ -> should.fail()
  }
}

pub fn quota_exceeded_over_limit_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(new_state, _) =
    pure.charge(state, "agent_1", LLMTokensPrompt, 150, timestamp)

  case pure.quota_exceeded(new_state, "agent_1", LLMTokensPrompt, 100) {
    Error(QuotaExceeded(_agent_id, _resource, current, limit)) -> {
      current
      |> should.equal(150)
      limit
      |> should.equal(100)
    }
    Ok(_) -> should.fail()
    _ -> should.fail()
  }
}

pub fn quota_exceeded_nonexistent_agent_test() {
  let state = empty_state()

  // Nonexistent agents pass quota checks (no usage yet)
  pure.quota_exceeded(state, "nonexistent", LLMTokensPrompt, 100)
  |> should.be_ok()
}

// ============================================================================
// reset Tests
// ============================================================================

pub fn reset_clears_counters_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(state1, _) =
    pure.charge(state, "agent_1", LLMTokensPrompt, 100, timestamp)
  let #(state2, _) =
    pure.charge(state1, "agent_1", LLMTokensCompletion, 50, timestamp)

  let #(new_state, commands) = pure.reset(state2, "agent_1", timestamp)

  let assert Ok(counters) = pure.snapshot(new_state, "agent_1")
  counters.llm_tokens_prompt
  |> should.equal(0)
  counters.llm_tokens_completion
  |> should.equal(0)

  list.length(commands)
  |> should.equal(2)
}

// ============================================================================
// total_tokens Tests
// ============================================================================

pub fn total_tokens_sums_correctly_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(state1, _) =
    pure.charge(state, "agent_1", LLMTokensPrompt, 100, timestamp)
  let #(state2, _) =
    pure.charge(state1, "agent_1", LLMTokensCompletion, 50, timestamp)

  pure.total_tokens(state2, "agent_1")
  |> should.equal(150)
}

pub fn total_tokens_nonexistent_agent_test() {
  let state = empty_state()

  pure.total_tokens(state, "nonexistent")
  |> should.equal(0)
}

// ============================================================================
// total_tool_calls Tests
// ============================================================================

pub fn total_tool_calls_sums_correctly_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(state1, _) =
    pure.charge(state, "agent_1", ToolCall("echo"), 1, timestamp)
  let #(state2, _) =
    pure.charge(state1, "agent_1", ToolCall("echo"), 1, timestamp)
  let #(state3, _) =
    pure.charge(state2, "agent_1", ToolCall("calc"), 1, timestamp)

  pure.total_tool_calls(state3, "agent_1")
  |> should.equal(3)
}

pub fn total_tool_calls_nonexistent_agent_test() {
  let state = empty_state()

  pure.total_tool_calls(state, "nonexistent")
  |> should.equal(0)
}
