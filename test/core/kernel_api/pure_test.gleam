//// KernelAPI — Pure Tests
////
//// Tests for pure functions in the kernel API.

import gleam/string
import gleeunit/should
import supernova/core/kernel_api/pure
import supernova/core/kernel_api/types
import supernova/core/kernel_scheduler/types as scheduler_types

// ============================================================================
// Operation Validation Tests
// ============================================================================

pub fn validate_set_priority_valid_test() {
  pure.validate_set_priority("agent_1", scheduler_types.Normal)
  |> should.be_ok
}

pub fn validate_set_priority_empty_agent_id_test() {
  pure.validate_set_priority("", scheduler_types.High)
  |> should.be_error
}

pub fn validate_audit_recent_valid_test() {
  pure.validate_audit_recent("agent_1", 10)
  |> should.be_ok
}

pub fn validate_audit_recent_empty_agent_id_test() {
  pure.validate_audit_recent("", 10)
  |> should.be_error
}

pub fn validate_audit_recent_zero_limit_test() {
  pure.validate_audit_recent("agent_1", 0)
  |> should.be_error
}

pub fn validate_audit_recent_negative_limit_test() {
  pure.validate_audit_recent("agent_1", -5)
  |> should.be_error
}

pub fn validate_world_query_empty_pattern_test() {
  pure.validate_world_query("")
  |> should.be_ok
}

pub fn validate_world_query_any_pattern_test() {
  pure.validate_world_query("any pattern")
  |> should.be_ok
}

// ============================================================================
// Result Formatting Tests
// ============================================================================

pub fn status_from_summaries_empty_test() {
  let assert types.KernelApiOk(data) = pure.status_from_summaries([])
  data |> should.equal("[]")
}

pub fn status_from_summaries_single_agent_test() {
  let summaries = [
    types.AgentStatusSummary(
      agent_id: "agent_1",
      status: "running",
      priority: "high",
      budget_remaining: 50,
      last_run: 1000,
    ),
  ]
  let assert types.KernelApiOk(data) = pure.status_from_summaries(summaries)
  data
  |> should.equal(
    "[{\"agent_id\":\"agent_1\",\"status\":\"running\",\"priority\":\"high\",\"budget_remaining\":50,\"last_run\":1000}]",
  )
}

pub fn status_from_summaries_multiple_agents_test() {
  let summaries = [
    types.AgentStatusSummary(
      agent_id: "agent_1",
      status: "running",
      priority: "high",
      budget_remaining: 50,
      last_run: 1000,
    ),
    types.AgentStatusSummary(
      agent_id: "agent_2",
      status: "idle",
      priority: "normal",
      budget_remaining: 100,
      last_run: 2000,
    ),
  ]
  let assert types.KernelApiOk(data) = pure.status_from_summaries(summaries)
  data |> string.contains("agent_1") |> should.be_true
  data |> string.contains("agent_2") |> should.be_true
  data |> string.contains("running") |> should.be_true
  data |> string.contains("idle") |> should.be_true
}

pub fn set_priority_result_test() {
  let assert types.KernelApiOk(data) = pure.set_priority_result("agent_1")
  data |> should.equal("priority_updated:agent_1")
}

pub fn error_result_test() {
  let assert types.KernelApiError(msg) =
    pure.error_result("something went wrong")
  msg |> should.equal("something went wrong")
}

// ============================================================================
// Priority Parsing Tests
// ============================================================================

pub fn parse_priority_critical_test() {
  pure.parse_priority("critical")
  |> should.be_ok
  |> should.equal(scheduler_types.Critical)
}

pub fn parse_priority_high_test() {
  pure.parse_priority("high")
  |> should.be_ok
  |> should.equal(scheduler_types.High)
}

pub fn parse_priority_normal_test() {
  pure.parse_priority("normal")
  |> should.be_ok
  |> should.equal(scheduler_types.Normal)
}

pub fn parse_priority_low_test() {
  pure.parse_priority("low")
  |> should.be_ok
  |> should.equal(scheduler_types.Low)
}

pub fn parse_priority_case_insensitive_test() {
  pure.parse_priority("HIGH")
  |> should.be_ok
  |> should.equal(scheduler_types.High)
  pure.parse_priority("High")
  |> should.be_ok
  |> should.equal(scheduler_types.High)
}

pub fn parse_priority_invalid_test() {
  pure.parse_priority("invalid")
  |> should.be_error
}

pub fn priority_to_string_critical_test() {
  pure.priority_to_string(scheduler_types.Critical)
  |> should.equal("critical")
}

pub fn priority_to_string_high_test() {
  pure.priority_to_string(scheduler_types.High)
  |> should.equal("high")
}

pub fn priority_to_string_normal_test() {
  pure.priority_to_string(scheduler_types.Normal)
  |> should.equal("normal")
}

pub fn priority_to_string_low_test() {
  pure.priority_to_string(scheduler_types.Low)
  |> should.equal("low")
}
