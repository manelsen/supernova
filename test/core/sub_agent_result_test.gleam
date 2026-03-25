//// US-018 Tests — Typed SubAgentResult
////
//// Covers:
//// - Successful result with all fields populated
//// - Typed failure result (ResultFailure status)
//// - Artifacts listed in result

import gleam/dynamic
import gleam/dynamic/decode
import gleam/list
import gleeunit
import supernova/core/sub_agent

pub fn main() -> Nil {
  gleeunit.main()
}

// Test: Successful result has ResultSuccess status and populated output
pub fn successful_result_test() {
  let config = sub_agent.default_config()
  let assert Ok(agent) = sub_agent.spawn("test-parent", "Write report", config)

  let result = sub_agent.get_result(agent)

  // Status must be ResultSuccess
  assert result.status == sub_agent.ResultSuccess

  // agent_id must be non-empty
  assert result.agent_id != ""

  // Output must be a valid string
  let assert Ok(output_str) = decode.run(result.output, decode.string)
  assert output_str != ""

  // tokens_used and duration_ms must be non-negative
  assert result.tokens_used >= 0
  assert result.duration_ms >= 0

  sub_agent.stop(agent)
}

// Test: Typed failure result has ResultFailure status
pub fn typed_failure_result_test() {
  // max_depth == current_depth forces a failure
  let config = sub_agent.config_with_depth(1, 1)
  let assert Ok(agent) =
    sub_agent.spawn("test-parent", "Impossible task", config)

  let result = sub_agent.get_result(agent)

  // Status must be ResultFailure (not just a string error)
  assert result.status == sub_agent.ResultFailure

  // agent_id is still populated
  assert result.agent_id != ""

  sub_agent.stop(agent)
}

// Test: Artifacts are listed in successful result
pub fn artifacts_listed_test() {
  let config = sub_agent.default_config()
  let assert Ok(agent) = sub_agent.spawn("test-parent", "Generate file", config)

  let result = sub_agent.get_result(agent)

  // Mock execution produces one artifact
  assert result.artifacts != []

  // Artifact paths should be non-empty strings
  let assert Ok(artifact) = list.first(result.artifacts)
  assert artifact != ""

  sub_agent.stop(agent)
}

// Test: Cancelled agent produces ResultPartial
pub fn cancelled_result_is_partial_test() {
  let config = sub_agent.default_config()
  let assert Ok(agent) = sub_agent.spawn("test-parent", "Long task", config)

  let _ = sub_agent.cancel(agent)
  let result = sub_agent.get_result(agent)

  assert result.status == sub_agent.ResultPartial

  sub_agent.stop(agent)
}

// Test: SubAgentResult fields match the US-018 spec
pub fn result_fields_match_spec_test() {
  let config = sub_agent.default_config()
  let assert Ok(agent) = sub_agent.spawn("spec-parent", "Spec test", config)

  let result = sub_agent.get_result(agent)

  // All required US-018 fields are present and correctly typed
  let _agent_id: String = result.agent_id
  let _status: sub_agent.SubAgentResultStatus = result.status
  let _output: dynamic.Dynamic = result.output
  let _artifacts: List(String) = result.artifacts
  let _tokens_used: Int = result.tokens_used
  let _duration_ms: Int = result.duration_ms

  // Sanity check values
  assert result.agent_id != ""
  assert result.tokens_used >= 0

  sub_agent.stop(agent)
}
