//// Tests for the Resource Ledger Actor module
////
//// Integration tests — with actors, with I/O.

import gleam/dict
import gleam/erlang/process
import gleeunit
import gleeunit/should
import supernova/core/resource_ledger/actor
import supernova/core/resource_ledger/types.{LLMTokensPrompt}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Actor Lifecycle Tests
// ============================================================================

pub fn start_and_stop_test() {
  let assert Ok(ledger) = actor.start()
  actor.stop(ledger)

  // Give actor time to terminate
  process.sleep(100)
}

// ============================================================================
// charge_llm Tests
// ============================================================================

pub fn charge_llm_creates_counters_test() {
  let assert Ok(ledger) = actor.start()

  let assert Ok(_) = actor.charge_llm(ledger, "agent_1", 100, 50)

  let assert Ok(counters) = actor.get_snapshot(ledger, "agent_1")
  counters.llm_tokens_prompt
  |> should.equal(100)
  counters.llm_tokens_completion
  |> should.equal(50)

  actor.stop(ledger)
  process.sleep(100)
}

pub fn charge_llm_accumulates_test() {
  let assert Ok(ledger) = actor.start()

  let assert Ok(_) = actor.charge_llm(ledger, "agent_1", 100, 50)
  let assert Ok(_) = actor.charge_llm(ledger, "agent_1", 50, 25)

  let assert Ok(counters) = actor.get_snapshot(ledger, "agent_1")
  counters.llm_tokens_prompt
  |> should.equal(150)
  counters.llm_tokens_completion
  |> should.equal(75)

  actor.stop(ledger)
  process.sleep(100)
}

// ============================================================================
// charge_tool Tests
// ============================================================================

pub fn charge_tool_creates_counters_test() {
  let assert Ok(ledger) = actor.start()

  let assert Ok(_) = actor.charge_tool(ledger, "agent_1", "echo")

  let assert Ok(counters) = actor.get_snapshot(ledger, "agent_1")
  let assert Ok(count) = dict.get(counters.tool_calls, "echo")
  count
  |> should.equal(1)

  actor.stop(ledger)
  process.sleep(100)
}

pub fn charge_tool_multiple_times_test() {
  let assert Ok(ledger) = actor.start()

  let assert Ok(_) = actor.charge_tool(ledger, "agent_1", "echo")
  let assert Ok(_) = actor.charge_tool(ledger, "agent_1", "echo")
  let assert Ok(_) = actor.charge_tool(ledger, "agent_1", "calc")

  let assert Ok(counters) = actor.get_snapshot(ledger, "agent_1")
  let assert Ok(echo_count) = dict.get(counters.tool_calls, "echo")
  let assert Ok(calc_count) = dict.get(counters.tool_calls, "calc")

  echo_count
  |> should.equal(2)
  calc_count
  |> should.equal(1)

  actor.stop(ledger)
  process.sleep(100)
}

// ============================================================================
// charge_storage Tests
// ============================================================================

pub fn charge_storage_creates_counters_test() {
  let assert Ok(ledger) = actor.start()

  let assert Ok(_) = actor.charge_storage(ledger, "agent_1", 10, 5)

  let assert Ok(counters) = actor.get_snapshot(ledger, "agent_1")
  counters.storage_reads
  |> should.equal(10)
  counters.storage_writes
  |> should.equal(5)

  actor.stop(ledger)
  process.sleep(100)
}

// ============================================================================
// charge_cpu Tests
// ============================================================================

pub fn charge_cpu_creates_counters_test() {
  let assert Ok(ledger) = actor.start()

  let assert Ok(_) = actor.charge_cpu(ledger, "agent_1", 1000)

  let assert Ok(counters) = actor.get_snapshot(ledger, "agent_1")
  counters.cpu_time_ms
  |> should.equal(1000)

  actor.stop(ledger)
  process.sleep(100)
}

// ============================================================================
// get_snapshot Tests
// ============================================================================

pub fn get_snapshot_nonexistent_agent_test() {
  let assert Ok(ledger) = actor.start()

  actor.get_snapshot(ledger, "nonexistent")
  |> should.be_error()

  actor.stop(ledger)
  process.sleep(100)
}

// ============================================================================
// check_quota Tests
// ============================================================================

pub fn check_quota_under_limit_test() {
  let assert Ok(ledger) = actor.start()

  let assert Ok(_) = actor.charge_llm(ledger, "agent_1", 100, 50)

  actor.check_quota(ledger, "agent_1", LLMTokensPrompt, 200)
  |> should.be_ok()

  actor.stop(ledger)
  process.sleep(100)
}

pub fn check_quota_exceeded_test() {
  let assert Ok(ledger) = actor.start()

  let assert Ok(_) = actor.charge_llm(ledger, "agent_1", 150, 50)

  actor.check_quota(ledger, "agent_1", LLMTokensPrompt, 100)
  |> should.be_error()

  actor.stop(ledger)
  process.sleep(100)
}

// ============================================================================
// reset_counters Tests
// ============================================================================

pub fn reset_counters_clears_state_test() {
  let assert Ok(ledger) = actor.start()

  let assert Ok(_) = actor.charge_llm(ledger, "agent_1", 100, 50)
  let assert Ok(_) = actor.reset_counters(ledger, "agent_1")

  let assert Ok(counters) = actor.get_snapshot(ledger, "agent_1")
  counters.llm_tokens_prompt
  |> should.equal(0)
  counters.llm_tokens_completion
  |> should.equal(0)

  actor.stop(ledger)
  process.sleep(100)
}

// ============================================================================
// get_total_tokens Tests
// ============================================================================

pub fn get_total_tokens_sums_correctly_test() {
  let assert Ok(ledger) = actor.start()

  let assert Ok(_) = actor.charge_llm(ledger, "agent_1", 100, 50)

  let total = actor.get_total_tokens(ledger, "agent_1")
  total
  |> should.equal(150)

  actor.stop(ledger)
  process.sleep(100)
}

// ============================================================================
// get_total_tool_calls Tests
// ============================================================================

pub fn get_total_tool_calls_sums_correctly_test() {
  let assert Ok(ledger) = actor.start()

  let assert Ok(_) = actor.charge_tool(ledger, "agent_1", "echo")
  let assert Ok(_) = actor.charge_tool(ledger, "agent_1", "echo")
  let assert Ok(_) = actor.charge_tool(ledger, "agent_1", "calc")

  let total = actor.get_total_tool_calls(ledger, "agent_1")
  total
  |> should.equal(3)

  actor.stop(ledger)
  process.sleep(100)
}

// ============================================================================
// Multiple Agents Tests
// ============================================================================

pub fn multiple_agents_independent_test() {
  let assert Ok(ledger) = actor.start()

  let assert Ok(_) = actor.charge_llm(ledger, "agent_1", 100, 50)
  let assert Ok(_) = actor.charge_llm(ledger, "agent_2", 200, 100)

  let assert Ok(counters1) = actor.get_snapshot(ledger, "agent_1")
  let assert Ok(counters2) = actor.get_snapshot(ledger, "agent_2")

  counters1.llm_tokens_prompt
  |> should.equal(100)
  counters2.llm_tokens_prompt
  |> should.equal(200)

  actor.stop(ledger)
  process.sleep(100)
}
