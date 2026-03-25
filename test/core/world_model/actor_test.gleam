//// Tests for the WorldModel Actor
////
//// Integration tests — start real actors, test full lifecycle.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import supernova/core/workspace_policy/actor as policy_actor
import supernova/core/world_model/actor as wm_actor
import supernova/core/world_model/types.{
  FactConstraint, FactDecision, FactEntity, FactGoal, FactPattern,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Lifecycle Tests
// ============================================================================

pub fn start_and_stop_test() {
  let assert Ok(wm) = wm_actor.start()
  wm_actor.stop(wm)
}

pub fn initial_version_is_zero_test() {
  let assert Ok(wm) = wm_actor.start()
  wm_actor.version(wm) |> should.equal(0)
  wm_actor.stop(wm)
}

// ============================================================================
// assert Tests
// ============================================================================

pub fn assert_fact_returns_fact_id_test() {
  let assert Ok(wm) = wm_actor.start()
  let result =
    wm_actor.assert_fact(wm, "agent_1", "sky is blue", FactEntity, 0.9)
  result |> should.be_ok()
  wm_actor.stop(wm)
}

pub fn assert_fact_increments_version_test() {
  let assert Ok(wm) = wm_actor.start()
  wm_actor.version(wm) |> should.equal(0)
  let assert Ok(_) = wm_actor.assert_fact(wm, "a", "fact 1", FactEntity, 1.0)
  wm_actor.version(wm) |> should.equal(1)
  let assert Ok(_) = wm_actor.assert_fact(wm, "a", "fact 2", FactDecision, 0.8)
  wm_actor.version(wm) |> should.equal(2)
  wm_actor.stop(wm)
}

pub fn assert_fact_invalid_confidence_test() {
  let assert Ok(wm) = wm_actor.start()
  let result = wm_actor.assert_fact(wm, "a", "bad", FactEntity, 1.5)
  result |> should.be_error()
  wm_actor.stop(wm)
}

pub fn two_agents_read_same_fact_test() {
  let assert Ok(wm) = wm_actor.start()
  let assert Ok(fact_id) =
    wm_actor.assert_fact(wm, "agent_1", "shared knowledge", FactEntity, 1.0)

  // Both agents can query the same fact without copying
  let facts_from_a1 = wm_actor.query(wm, types.any_pattern())
  let facts_from_a2 = wm_actor.query(wm, types.any_pattern())

  list.length(facts_from_a1) |> should.equal(1)
  list.length(facts_from_a2) |> should.equal(1)
  let assert [f1] = facts_from_a1
  let assert [f2] = facts_from_a2
  f1.id |> should.equal(fact_id)
  f2.id |> should.equal(fact_id)

  wm_actor.stop(wm)
}

// ============================================================================
// retract Tests
// ============================================================================

pub fn retract_tombstones_fact_test() {
  let assert Ok(wm) = wm_actor.start()
  let assert Ok(fact_id) =
    wm_actor.assert_fact(wm, "agent_1", "to be retracted", FactDecision, 0.7)
  let result = wm_actor.retract(wm, "agent_1", fact_id, "no longer valid")
  result |> should.equal(Ok(Nil))
  // Tombstoned facts not returned by query
  wm_actor.query(wm, types.any_pattern()) |> should.equal([])
  wm_actor.stop(wm)
}

pub fn retract_not_found_returns_error_test() {
  let assert Ok(wm) = wm_actor.start()
  let result = wm_actor.retract(wm, "agent_1", "nonexistent_id", "reason")
  result |> should.be_error()
  wm_actor.stop(wm)
}

pub fn retract_already_tombstoned_returns_error_test() {
  let assert Ok(wm) = wm_actor.start()
  let assert Ok(fact_id) =
    wm_actor.assert_fact(wm, "agent_1", "fact", FactEntity, 0.9)
  let assert Ok(Nil) = wm_actor.retract(wm, "agent_1", fact_id, "first")
  let result = wm_actor.retract(wm, "agent_1", fact_id, "second")
  result |> should.be_error()
  wm_actor.stop(wm)
}

pub fn retract_increments_version_test() {
  let assert Ok(wm) = wm_actor.start()
  let assert Ok(fact_id) =
    wm_actor.assert_fact(wm, "a", "fact", FactEntity, 1.0)
  let v_before = wm_actor.version(wm)
  let assert Ok(Nil) = wm_actor.retract(wm, "a", fact_id, "outdated")
  wm_actor.version(wm) |> should.equal(v_before + 1)
  wm_actor.stop(wm)
}

// ============================================================================
// query Tests
// ============================================================================

pub fn query_by_type_test() {
  let assert Ok(wm) = wm_actor.start()
  let assert Ok(_) =
    wm_actor.assert_fact(wm, "a", "entity fact", FactEntity, 1.0)
  let assert Ok(_) =
    wm_actor.assert_fact(wm, "a", "decision fact", FactDecision, 0.8)
  let pattern =
    FactPattern(
      fact_type: Some(FactEntity),
      author: None,
      content_contains: None,
    )
  let facts = wm_actor.query(wm, pattern)
  list.length(facts) |> should.equal(1)
  let assert [f] = facts
  f.fact_type |> should.equal(FactEntity)
  wm_actor.stop(wm)
}

pub fn query_by_author_test() {
  let assert Ok(wm) = wm_actor.start()
  let assert Ok(_) =
    wm_actor.assert_fact(wm, "alice", "from alice", FactGoal, 0.9)
  let assert Ok(_) = wm_actor.assert_fact(wm, "bob", "from bob", FactGoal, 0.7)
  let pattern =
    FactPattern(fact_type: None, author: Some("alice"), content_contains: None)
  let facts = wm_actor.query(wm, pattern)
  list.length(facts) |> should.equal(1)
  let assert [f] = facts
  f.author |> should.equal("alice")
  wm_actor.stop(wm)
}

pub fn query_by_content_test() {
  let assert Ok(wm) = wm_actor.start()
  let assert Ok(_) =
    wm_actor.assert_fact(wm, "a", "goal: ship feature", FactGoal, 1.0)
  let assert Ok(_) =
    wm_actor.assert_fact(wm, "a", "constraint: deadline", FactConstraint, 1.0)
  let pattern =
    FactPattern(fact_type: None, author: None, content_contains: Some("ship"))
  let facts = wm_actor.query(wm, pattern)
  list.length(facts) |> should.equal(1)
  wm_actor.stop(wm)
}

// ============================================================================
// subscribe / notification Tests
// ============================================================================

pub fn subscribe_receives_new_fact_test() {
  let assert Ok(wm) = wm_actor.start()
  let subject = process.new_subject()
  let pattern = types.any_pattern()
  wm_actor.subscribe(wm, pattern, subject)

  let assert Ok(_fact_id) =
    wm_actor.assert_fact(wm, "a", "subscribed fact", FactEntity, 1.0)

  // Notification should arrive within 1 second
  let result = process.receive(subject, 1000)
  result |> should.be_ok()
  let assert Ok(fact) = result
  fact.content |> should.equal("subscribed fact")
  wm_actor.stop(wm)
}

pub fn subscribe_receives_retract_notification_test() {
  let assert Ok(wm) = wm_actor.start()
  let subject = process.new_subject()
  wm_actor.subscribe(wm, types.any_pattern(), subject)

  let assert Ok(fact_id) =
    wm_actor.assert_fact(wm, "a", "will be retracted", FactDecision, 0.6)
  // Consume the assert notification
  let _ = process.receive(subject, 1000)

  let assert Ok(Nil) = wm_actor.retract(wm, "a", fact_id, "no longer true")
  // Receive retract notification
  let result = process.receive(subject, 1000)
  result |> should.be_ok()
  let assert Ok(tombstoned) = result
  tombstoned.tombstone |> should.equal(True)

  wm_actor.stop(wm)
}

pub fn subscribe_pattern_filters_notifications_test() {
  let assert Ok(wm) = wm_actor.start()
  let subject = process.new_subject()
  // Only subscribe to FactGoal
  let pattern =
    FactPattern(fact_type: Some(FactGoal), author: None, content_contains: None)
  wm_actor.subscribe(wm, pattern, subject)

  // Assert a non-matching fact (FactEntity) — should NOT notify
  let assert Ok(_) =
    wm_actor.assert_fact(wm, "a", "entity fact", FactEntity, 1.0)
  // Assert a matching fact (FactGoal) — should notify
  let assert Ok(_) = wm_actor.assert_fact(wm, "a", "goal fact", FactGoal, 0.9)

  // Should receive exactly the goal fact
  let result = process.receive(subject, 1000)
  result |> should.be_ok()
  let assert Ok(fact) = result
  fact.fact_type |> should.equal(FactGoal)

  // No more notifications
  let no_more = process.receive(subject, 100)
  no_more |> should.be_error()

  wm_actor.stop(wm)
}

// ============================================================================
// Permission Tests (WorkspacePolicy integration)
// ============================================================================

pub fn agent_without_permission_cannot_assert_test() {
  // Start a policy that grants agent_x only access to "files" — not "world_model"
  // When allowed_paths is non-empty, only those prefixes are permitted.
  // The world model passes relative path "world_model"; full_path becomes
  // "workspaces/agent_x/world_model". Since agent_x's allowed_paths contains
  // only "workspaces/agent_x/files", the world_model path is denied.
  let assert Ok(policy) = policy_actor.start("workspaces")
  policy_actor.allow_path(policy, "agent_x", "workspaces/agent_x/files")

  let assert Ok(wm) = wm_actor.start_with_policy(policy)

  // agent_x should be denied — "world_model" is not in allowed list
  let result = wm_actor.assert_fact(wm, "agent_x", "fact", FactEntity, 1.0)
  result |> should.be_error()

  wm_actor.stop(wm)
  policy_actor.stop(policy)
}

pub fn agent_with_permission_can_assert_test() {
  // Allow agent_ok access to its entire workspace (covers "world_model" sub-path)
  // full_path = "workspaces/agent_ok/world_model" starts_with "workspaces/agent_ok" → allowed
  let assert Ok(policy) = policy_actor.start("workspaces")
  policy_actor.allow_path(policy, "agent_ok", "workspaces/agent_ok")

  let assert Ok(wm) = wm_actor.start_with_policy(policy)
  let result =
    wm_actor.assert_fact(wm, "agent_ok", "allowed fact", FactEntity, 1.0)
  result |> should.be_ok()

  wm_actor.stop(wm)
  policy_actor.stop(policy)
}

// ============================================================================
// Concurrency Tests
// ============================================================================

pub fn concurrent_asserts_test() {
  let assert Ok(wm) = wm_actor.start()
  // Assert multiple facts in sequence (actor serializes them)
  let assert Ok(id1) = wm_actor.assert_fact(wm, "a", "fact 1", FactEntity, 1.0)
  let assert Ok(id2) = wm_actor.assert_fact(wm, "b", "fact 2", FactEntity, 0.9)
  let assert Ok(id3) = wm_actor.assert_fact(wm, "c", "fact 3", FactEntity, 0.8)
  // All three should be distinct
  id1 |> should.not_equal(id2)
  id2 |> should.not_equal(id3)
  // Version should reflect all three asserts
  wm_actor.version(wm) |> should.equal(3)
  wm_actor.stop(wm)
}

pub fn versioning_across_assert_and_retract_test() {
  let assert Ok(wm) = wm_actor.start()
  let assert Ok(id) = wm_actor.assert_fact(wm, "a", "fact", FactEntity, 1.0)
  wm_actor.version(wm) |> should.equal(1)
  let assert Ok(Nil) = wm_actor.retract(wm, "a", id, "done")
  wm_actor.version(wm) |> should.equal(2)
  // Version never decreases
  let assert Ok(_) =
    wm_actor.assert_fact(wm, "a", "new fact", FactDecision, 0.5)
  wm_actor.version(wm) |> should.equal(3)
  wm_actor.stop(wm)
}
