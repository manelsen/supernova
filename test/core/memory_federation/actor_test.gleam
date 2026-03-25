//// Tests for the MemoryFederation Actor
////
//// Integration tests — uses real WorldModel actor and real Federation actor.

import gleam/erlang/process
import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/memory_federation/actor as fed_actor
import supernova/core/memory_federation/types
import supernova/core/world_model/actor as wm_actor
import supernova/core/world_model/types as wm_types

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helpers
// ============================================================================

fn make_candidate(content: String, relevance: Float) {
  types.CandidateFact(
    content: content,
    relevance: relevance,
    session_id: "session_1",
    tags: [],
  )
}

// ============================================================================
// Actor lifecycle
// ============================================================================

pub fn actor_starts_and_stops_test() {
  let assert Ok(wm) = wm_actor.start()
  let config = types.default_config("agent_test")
  let assert Ok(fed) = fed_actor.start(config, wm)
  fed_actor.stop(fed)
  wm_actor.stop(wm)
  process.sleep(50)
}

// ============================================================================
// federate — promotion to WorldModel
// ============================================================================

pub fn actor_promotes_high_relevance_fact_test() {
  let assert Ok(wm) = wm_actor.start()
  let config = types.default_config("agent_test")
  let assert Ok(fed) = fed_actor.start(config, wm)

  let candidates = [make_candidate("the sky is blue", 0.9)]
  let result = fed_actor.federate(fed, "session_1", candidates)

  // One fact promoted to WorldModel
  list.length(result.promoted) |> should.equal(1)
  result.kept_local |> should.equal(0)
  result.rejected |> should.equal(0)

  // Fact actually appears in WorldModel
  let facts = wm_actor.query(wm, wm_types.any_pattern())
  list.length(facts) |> should.equal(1)

  fed_actor.stop(fed)
  wm_actor.stop(wm)
  process.sleep(50)
}

pub fn actor_keeps_local_medium_relevance_fact_test() {
  let assert Ok(wm) = wm_actor.start()
  let config = types.default_config("agent_test")
  let assert Ok(fed) = fed_actor.start(config, wm)

  let candidates = [make_candidate("only somewhat relevant", 0.5)]
  let result = fed_actor.federate(fed, "session_1", candidates)

  // Not promoted — kept local
  result.promoted |> should.equal([])
  result.kept_local |> should.equal(1)
  result.rejected |> should.equal(0)

  // WorldModel remains empty
  let facts = wm_actor.query(wm, wm_types.any_pattern())
  facts |> should.equal([])

  fed_actor.stop(fed)
  wm_actor.stop(wm)
  process.sleep(50)
}

pub fn actor_rejects_low_relevance_fact_test() {
  let assert Ok(wm) = wm_actor.start()
  let config = types.default_config("agent_test")
  let assert Ok(fed) = fed_actor.start(config, wm)

  let candidates = [make_candidate("irrelevant noise", 0.1)]
  let result = fed_actor.federate(fed, "session_1", candidates)

  result.promoted |> should.equal([])
  result.kept_local |> should.equal(0)
  result.rejected |> should.equal(1)

  fed_actor.stop(fed)
  wm_actor.stop(wm)
  process.sleep(50)
}

// ============================================================================
// federate — multiple candidates with mixed relevance
// ============================================================================

pub fn actor_federates_mixed_candidates_test() {
  let assert Ok(wm) = wm_actor.start()
  let config = types.default_config("agent_test")
  let assert Ok(fed) = fed_actor.start(config, wm)

  let candidates = [
    make_candidate("important global fact", 0.9),
    make_candidate("another global fact", 0.75),
    make_candidate("local only fact", 0.5),
    make_candidate("another local fact", 0.4),
    make_candidate("noise A", 0.1),
    make_candidate("noise B", 0.2),
  ]
  let result = fed_actor.federate(fed, "session_1", candidates)

  // 2 promoted, 2 kept, 2 rejected
  list.length(result.promoted) |> should.equal(2)
  result.kept_local |> should.equal(2)
  result.rejected |> should.equal(2)

  // Two facts should be in WorldModel
  let facts = wm_actor.query(wm, wm_types.any_pattern())
  list.length(facts) |> should.equal(2)

  fed_actor.stop(fed)
  wm_actor.stop(wm)
  process.sleep(50)
}

// ============================================================================
// federate — threshold configuration
// ============================================================================

pub fn actor_respects_custom_threshold_test() {
  let assert Ok(wm) = wm_actor.start()
  // Very strict threshold — only facts with relevance >= 0.95 are promoted
  let config =
    types.FederationConfig(
      global_threshold: 0.95,
      local_threshold: 0.5,
      agent_id: "strict_agent",
    )
  let assert Ok(fed) = fed_actor.start(config, wm)

  let candidates = [
    make_candidate("extremely confident fact", 0.98),
    make_candidate("high but below strict threshold", 0.9),
  ]
  let result = fed_actor.federate(fed, "session_1", candidates)

  // Only 0.98 promoted; 0.9 kept local
  list.length(result.promoted) |> should.equal(1)
  result.kept_local |> should.equal(1)
  result.rejected |> should.equal(0)

  fed_actor.stop(fed)
  wm_actor.stop(wm)
  process.sleep(50)
}

pub fn actor_empty_candidates_returns_empty_result_test() {
  let assert Ok(wm) = wm_actor.start()
  let config = types.default_config("agent_test")
  let assert Ok(fed) = fed_actor.start(config, wm)

  let result = fed_actor.federate(fed, "session_1", [])

  result.promoted |> should.equal([])
  result.kept_local |> should.equal(0)
  result.rejected |> should.equal(0)

  fed_actor.stop(fed)
  wm_actor.stop(wm)
  process.sleep(50)
}
