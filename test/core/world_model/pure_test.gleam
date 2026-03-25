//// Tests for the WorldModel Pure module
////
//// Pure tests — no I/O, no actors, no FFI.

import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import supernova/core/world_model/pure
import supernova/core/world_model/types.{
  FactConstraint, FactDecision, FactEntity, FactGoal, FactPattern,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helpers
// ============================================================================

fn empty_state() -> types.WorldModelState {
  types.initial_state()
}

fn assert_ok(state, content, fact_type, author, confidence) {
  pure.assert_fact(state, content, fact_type, author, confidence, 1000)
}

// ============================================================================
// assert_fact Tests
// ============================================================================

pub fn assert_returns_fact_id_test() {
  let state = empty_state()
  let #(_state, result, _cmds) =
    assert_ok(state, "sky is blue", FactEntity, "agent_1", 0.9)
  result |> should.be_ok()
}

pub fn assert_fact_id_increments_test() {
  let state = empty_state()
  let assert #(state1, Ok(id1), _) =
    assert_ok(state, "fact one", FactEntity, "a", 1.0)
  let assert #(_state2, Ok(id2), _) =
    assert_ok(state1, "fact two", FactDecision, "a", 0.5)
  id1 |> should.equal("fact_0")
  id2 |> should.equal("fact_1")
}

pub fn assert_increments_version_test() {
  let state = empty_state()
  pure.version(state) |> should.equal(0)
  let assert #(state1, Ok(_), _) =
    assert_ok(state, "fact", FactEntity, "a", 1.0)
  pure.version(state1) |> should.equal(1)
  let assert #(state2, Ok(_), _) =
    assert_ok(state1, "another", FactGoal, "a", 0.7)
  pure.version(state2) |> should.equal(2)
}

pub fn assert_stores_correct_fields_test() {
  let state = empty_state()
  let assert #(new_state, Ok(fact_id), _) =
    pure.assert_fact(
      state,
      "content here",
      FactConstraint,
      "agent_x",
      0.75,
      9999,
    )
  let facts = pure.query(new_state, types.any_pattern())
  let assert [fact] = facts
  fact.id |> should.equal(fact_id)
  fact.content |> should.equal("content here")
  fact.fact_type |> should.equal(FactConstraint)
  fact.author |> should.equal("agent_x")
  fact.confidence |> should.equal(0.75)
  fact.created_at |> should.equal(9999)
  fact.tombstone |> should.equal(False)
}

pub fn assert_invalid_confidence_above_1_test() {
  let state = empty_state()
  let #(_state, result, cmds) = assert_ok(state, "x", FactEntity, "a", 1.1)
  result |> should.be_error()
  cmds |> should.equal([])
}

pub fn assert_invalid_confidence_below_0_test() {
  let state = empty_state()
  let #(_state, result, cmds) = assert_ok(state, "x", FactEntity, "a", -0.1)
  result |> should.be_error()
  cmds |> should.equal([])
}

pub fn assert_boundary_confidence_0_test() {
  let state = empty_state()
  let #(_state, result, _) = assert_ok(state, "uncertain", FactEntity, "a", 0.0)
  result |> should.be_ok()
}

pub fn assert_boundary_confidence_1_test() {
  let state = empty_state()
  let #(_state, result, _) = assert_ok(state, "certain", FactEntity, "a", 1.0)
  result |> should.be_ok()
}

pub fn assert_emits_notify_command_test() {
  let state = empty_state()
  let assert #(_state, Ok(_), cmds) =
    assert_ok(state, "fact", FactEntity, "a", 0.9)
  let has_notify =
    list.any(cmds, fn(cmd) {
      case cmd {
        types.NotifyChange(_) -> True
        _ -> False
      }
    })
  has_notify |> should.equal(True)
}

// ============================================================================
// retract Tests
// ============================================================================

pub fn retract_tombstones_fact_test() {
  let state = empty_state()
  let assert #(state1, Ok(fact_id), _) =
    assert_ok(state, "fact", FactEntity, "a", 1.0)
  let #(state2, result, _) = pure.retract(state1, fact_id, "no longer true")
  result |> should.equal(Ok(Nil))
  // Tombstoned facts are excluded from query
  pure.query(state2, types.any_pattern()) |> should.equal([])
}

pub fn retract_not_found_test() {
  let state = empty_state()
  let #(_state, result, cmds) = pure.retract(state, "fact_99", "reason")
  result |> should.be_error()
  cmds |> should.equal([])
}

pub fn retract_already_tombstoned_test() {
  let state = empty_state()
  let assert #(state1, Ok(fact_id), _) =
    assert_ok(state, "fact", FactEntity, "a", 1.0)
  let assert #(state2, Ok(Nil), _) =
    pure.retract(state1, fact_id, "first retract")
  let #(_state3, result, _) = pure.retract(state2, fact_id, "second retract")
  result |> should.be_error()
}

pub fn retract_increments_version_test() {
  let state = empty_state()
  let assert #(state1, Ok(fact_id), _) =
    assert_ok(state, "fact", FactEntity, "a", 1.0)
  let v1 = pure.version(state1)
  let assert #(state2, Ok(Nil), _) = pure.retract(state1, fact_id, "outdated")
  pure.version(state2) |> should.equal(v1 + 1)
}

pub fn retract_emits_notify_command_test() {
  let state = empty_state()
  let assert #(state1, Ok(fact_id), _) =
    assert_ok(state, "fact", FactEntity, "a", 1.0)
  let assert #(_state2, Ok(Nil), cmds) = pure.retract(state1, fact_id, "reason")
  let has_notify =
    list.any(cmds, fn(cmd) {
      case cmd {
        types.NotifyChange(_) -> True
        _ -> False
      }
    })
  has_notify |> should.equal(True)
}

// ============================================================================
// query Tests
// ============================================================================

pub fn query_all_facts_test() {
  let state = empty_state()
  let assert #(state1, Ok(_), _) =
    assert_ok(state, "fact A", FactEntity, "a", 1.0)
  let assert #(state2, Ok(_), _) =
    assert_ok(state1, "fact B", FactDecision, "b", 0.8)
  let facts = pure.query(state2, types.any_pattern())
  list.length(facts) |> should.equal(2)
}

pub fn query_by_type_test() {
  let state = empty_state()
  let assert #(state1, Ok(_), _) =
    assert_ok(state, "an entity", FactEntity, "a", 1.0)
  let assert #(state2, Ok(_), _) =
    assert_ok(state1, "a decision", FactDecision, "a", 0.9)
  let pattern =
    FactPattern(
      fact_type: Some(FactEntity),
      author: None,
      content_contains: None,
    )
  let facts = pure.query(state2, pattern)
  list.length(facts) |> should.equal(1)
  let assert [f] = facts
  f.fact_type |> should.equal(FactEntity)
}

pub fn query_by_author_test() {
  let state = empty_state()
  let assert #(state1, Ok(_), _) =
    assert_ok(state, "from alice", FactEntity, "alice", 1.0)
  let assert #(state2, Ok(_), _) =
    assert_ok(state1, "from bob", FactEntity, "bob", 0.9)
  let pattern =
    FactPattern(fact_type: None, author: Some("alice"), content_contains: None)
  let facts = pure.query(state2, pattern)
  list.length(facts) |> should.equal(1)
  let assert [f] = facts
  f.author |> should.equal("alice")
}

pub fn query_by_content_contains_test() {
  let state = empty_state()
  let assert #(state1, Ok(_), _) =
    assert_ok(state, "the sky is blue", FactEntity, "a", 1.0)
  let assert #(state2, Ok(_), _) =
    assert_ok(state1, "grass is green", FactEntity, "a", 1.0)
  let pattern =
    FactPattern(fact_type: None, author: None, content_contains: Some("sky"))
  let facts = pure.query(state2, pattern)
  list.length(facts) |> should.equal(1)
  let assert [f] = facts
  f.content |> should.equal("the sky is blue")
}

pub fn query_excludes_tombstoned_test() {
  let state = empty_state()
  let assert #(state1, Ok(id1), _) =
    assert_ok(state, "live fact", FactEntity, "a", 1.0)
  let assert #(state2, Ok(_), _) =
    assert_ok(state1, "another fact", FactEntity, "a", 0.8)
  let assert #(state3, Ok(Nil), _) = pure.retract(state2, id1, "outdated")
  let facts = pure.query(state3, types.any_pattern())
  list.length(facts) |> should.equal(1)
  let assert [f] = facts
  f.tombstone |> should.equal(False)
}

pub fn query_combined_pattern_test() {
  let state = empty_state()
  let assert #(state1, Ok(_), _) =
    assert_ok(state, "goal: ship feature", FactGoal, "pm", 0.9)
  let assert #(state2, Ok(_), _) =
    assert_ok(state1, "goal: fix bug", FactGoal, "dev", 0.8)
  let assert #(state3, Ok(_), _) =
    assert_ok(state2, "constraint: deadline", FactConstraint, "pm", 1.0)
  let pattern =
    FactPattern(
      fact_type: Some(FactGoal),
      author: Some("pm"),
      content_contains: None,
    )
  let facts = pure.query(state3, pattern)
  list.length(facts) |> should.equal(1)
  let assert [f] = facts
  f.fact_type |> should.equal(FactGoal)
  f.author |> should.equal("pm")
}

// ============================================================================
// version Tests
// ============================================================================

pub fn version_starts_at_zero_test() {
  let state = empty_state()
  pure.version(state) |> should.equal(0)
}

pub fn version_increments_per_mutation_test() {
  let state = empty_state()
  let assert #(s1, Ok(id1), _) = assert_ok(state, "a", FactEntity, "x", 1.0)
  let assert #(s2, Ok(_id2), _) = assert_ok(s1, "b", FactEntity, "x", 1.0)
  let assert #(s3, Ok(Nil), _) = pure.retract(s2, id1, "done")
  pure.version(s3) |> should.equal(3)
}

// ============================================================================
// matches_pattern Tests
// ============================================================================

pub fn matches_pattern_any_matches_all_test() {
  let state = empty_state()
  let assert #(state1, Ok(_), _) =
    assert_ok(state, "anything", FactEntity, "agent", 0.5)
  let facts = pure.query(state1, types.any_pattern())
  list.length(facts) |> should.equal(1)
}
