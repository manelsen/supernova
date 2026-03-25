//// Tests for the MemoryFederation Pure module
////
//// Pure tests — no I/O, no actors, no FFI.

import gleeunit
import gleeunit/should
import supernova/core/memory_federation/pure
import supernova/core/memory_federation/types.{
  type CandidateFact, type FederationConfig, CandidateFact, FederationConfig,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helpers
// ============================================================================

fn default_config() -> FederationConfig {
  types.default_config("agent_1")
}

fn make_candidate(content: String, relevance: Float) -> CandidateFact {
  CandidateFact(
    content: content,
    relevance: relevance,
    session_id: "session_1",
    tags: [],
  )
}

fn make_state() -> types.FederationState {
  types.initial_state(default_config())
}

// ============================================================================
// federate — promotion (>= global_threshold)
// ============================================================================

pub fn federate_promotes_high_relevance_fact_test() {
  let state = make_state()
  let candidate = make_candidate("the sky is blue", 0.9)
  let #(_state, result, _cmds) = pure.federate(state, [candidate], "session_1")
  result.to_promote |> should.equal([candidate])
  result.kept_local |> should.equal(0)
  result.rejected |> should.equal(0)
}

pub fn federate_promotes_exactly_at_global_threshold_test() {
  // relevance == 0.7 exactly → should be promoted
  let state = make_state()
  let candidate = make_candidate("boundary fact", 0.7)
  let #(_state, result, _cmds) = pure.federate(state, [candidate], "session_1")
  result.to_promote |> should.equal([candidate])
  result.kept_local |> should.equal(0)
  result.rejected |> should.equal(0)
}

// ============================================================================
// federate — kept local (local_threshold <= relevance < global_threshold)
// ============================================================================

pub fn federate_keeps_medium_relevance_fact_local_test() {
  let state = make_state()
  let candidate = make_candidate("somewhat relevant", 0.5)
  let #(_state, result, _cmds) = pure.federate(state, [candidate], "session_1")
  result.to_promote |> should.equal([])
  result.kept_local |> should.equal(1)
  result.rejected |> should.equal(0)
}

pub fn federate_keeps_fact_at_local_threshold_test() {
  // relevance == 0.3 exactly → kept local, not rejected
  let state = make_state()
  let candidate = make_candidate("local boundary", 0.3)
  let #(_state, result, _cmds) = pure.federate(state, [candidate], "session_1")
  result.to_promote |> should.equal([])
  result.kept_local |> should.equal(1)
  result.rejected |> should.equal(0)
}

// ============================================================================
// federate — rejected (< local_threshold)
// ============================================================================

pub fn federate_rejects_low_relevance_fact_test() {
  let state = make_state()
  let candidate = make_candidate("irrelevant detail", 0.1)
  let #(_state, result, _cmds) = pure.federate(state, [candidate], "session_1")
  result.to_promote |> should.equal([])
  result.kept_local |> should.equal(0)
  result.rejected |> should.equal(1)
}

pub fn federate_rejects_zero_relevance_fact_test() {
  let state = make_state()
  let candidate = make_candidate("noise", 0.0)
  let #(_state, result, _cmds) = pure.federate(state, [candidate], "session_1")
  result.to_promote |> should.equal([])
  result.kept_local |> should.equal(0)
  result.rejected |> should.equal(1)
}

// ============================================================================
// federate — threshold respected across multiple candidates
// ============================================================================

pub fn federate_classifies_multiple_candidates_test() {
  let state = make_state()
  let candidates = [
    make_candidate("global fact A", 0.9),
    make_candidate("global fact B", 0.8),
    make_candidate("local fact C", 0.5),
    make_candidate("local fact D", 0.4),
    make_candidate("rejected E", 0.2),
    make_candidate("rejected F", 0.1),
  ]
  let #(_state, result, _cmds) = pure.federate(state, candidates, "session_1")
  // 2 promoted, 2 kept, 2 rejected
  result.to_promote
  |> should.equal([
    make_candidate("global fact A", 0.9),
    make_candidate("global fact B", 0.8),
  ])
  result.kept_local |> should.equal(2)
  result.rejected |> should.equal(2)
}

pub fn federate_empty_candidates_test() {
  let state = make_state()
  let #(_state, result, _cmds) = pure.federate(state, [], "session_1")
  result.to_promote |> should.equal([])
  result.kept_local |> should.equal(0)
  result.rejected |> should.equal(0)
}

pub fn federate_respects_custom_threshold_test() {
  // Custom high threshold: only very high relevance promotes
  let config =
    FederationConfig(
      global_threshold: 0.95,
      local_threshold: 0.5,
      agent_id: "agent_x",
    )
  let state = types.initial_state(config)
  let candidates = [
    make_candidate("very high", 0.98),
    make_candidate("high but not enough", 0.9),
    make_candidate("medium", 0.6),
    make_candidate("low", 0.3),
  ]
  let #(_state, result, _cmds) = pure.federate(state, candidates, "session_1")
  result.to_promote |> should.equal([make_candidate("very high", 0.98)])
  result.kept_local |> should.equal(2)
  result.rejected |> should.equal(1)
}

// ============================================================================
// federate — emits telemetry command
// ============================================================================

pub fn federate_emits_telemetry_command_test() {
  let state = make_state()
  let candidates = [make_candidate("some fact", 0.8)]
  let #(_state, _result, cmds) = pure.federate(state, candidates, "session_42")
  let has_telemetry = case cmds {
    [types.EmitTelemetry(name, _)] -> name == "federation:federate"
    _ -> False
  }
  has_telemetry |> should.equal(True)
}

pub fn federate_does_not_mutate_state_test() {
  // FederationState is stateless (no counters), calling twice should work identically
  let state = make_state()
  let candidate = make_candidate("fact", 0.8)
  let #(state1, result1, _) = pure.federate(state, [candidate], "s1")
  let #(_state2, result2, _) = pure.federate(state1, [candidate], "s1")
  result1.to_promote |> should.equal(result2.to_promote)
  result1.kept_local |> should.equal(result2.kept_local)
  result1.rejected |> should.equal(result2.rejected)
}
