//// Tests for the Checkpoint Actor module
////
//// Integration tests — with actors, with I/O.

import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import supernova/core/checkpoint/actor
import supernova/core/checkpoint/types.{Abort, Continue, Pause}
import supernova/llm/provider

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helpers
// ============================================================================

fn make_messages() -> List(provider.ChatMessage) {
  [
    provider.user_message("Hello"),
    provider.ChatMessage(
      role: "assistant",
      content: "Hi there",
      tool_call_id: None,
      tool_calls: None,
      reasoning_content: None,
    ),
  ]
}

// ============================================================================
// Lifecycle Tests
// ============================================================================

pub fn start_and_stop_test() {
  let assert Ok(store) = actor.start()
  actor.stop(store)
  process.sleep(100)
}

// ============================================================================
// save Tests
// ============================================================================

pub fn save_returns_checkpoint_id_test() {
  let assert Ok(store) = actor.start()

  let result = actor.save(store, "session_1", make_messages(), None, dict.new())
  result
  |> should.be_ok()

  actor.stop(store)
  process.sleep(100)
}

pub fn save_multiple_returns_unique_ids_test() {
  let assert Ok(store) = actor.start()

  let assert Ok(id1) =
    actor.save(store, "session_1", make_messages(), None, dict.new())
  let assert Ok(id2) =
    actor.save(store, "session_1", make_messages(), None, dict.new())

  id1
  |> should.not_equal(id2)

  actor.stop(store)
  process.sleep(100)
}

// ============================================================================
// restore Tests (checkpoint round-trip)
// ============================================================================

pub fn restore_success_test() {
  let assert Ok(store) = actor.start()

  let assert Ok(ckpt_id) =
    actor.save(store, "session_1", make_messages(), None, dict.new())
  let result = actor.restore(store, ckpt_id)

  result
  |> should.be_ok()

  actor.stop(store)
  process.sleep(100)
}

pub fn restore_not_found_fails_test() {
  let assert Ok(store) = actor.start()

  actor.restore(store, "nonexistent")
  |> should.be_error()

  actor.stop(store)
  process.sleep(100)
}

pub fn checkpoint_round_trip_history_preserved_test() {
  let assert Ok(store) = actor.start()

  let messages = make_messages()
  let assert Ok(ckpt_id) =
    actor.save(store, "session_1", messages, None, dict.new())

  let assert Ok(checkpoint) = actor.restore(store, ckpt_id)

  // History is fully preserved
  checkpoint.history
  |> should.equal(messages)

  // Session ID is preserved
  checkpoint.session_id
  |> should.equal("session_1")

  actor.stop(store)
  process.sleep(100)
}

pub fn checkpoint_round_trip_with_pending_tool_test() {
  let assert Ok(store) = actor.start()

  let tool_call =
    provider.ToolCall(id: "tc_1", name: "search", arguments: "{\"q\":\"test\"}")

  let assert Ok(ckpt_id) =
    actor.save(store, "session_1", [], Some(tool_call), dict.new())

  let assert Ok(checkpoint) = actor.restore(store, ckpt_id)

  checkpoint.pending_tool
  |> should.equal(Some(tool_call))

  actor.stop(store)
  process.sleep(100)
}

pub fn checkpoint_round_trip_metadata_preserved_test() {
  let assert Ok(store) = actor.start()

  let metadata = dict.from_list([#("env", "production"), #("version", "2.0")])
  let assert Ok(ckpt_id) = actor.save(store, "session_1", [], None, metadata)

  let assert Ok(checkpoint) = actor.restore(store, ckpt_id)

  checkpoint.context_metadata
  |> should.equal(metadata)

  actor.stop(store)
  process.sleep(100)
}

// ============================================================================
// should_yield Tests (forced yield)
// ============================================================================

pub fn should_yield_default_continue_test() {
  let assert Ok(store) = actor.start()

  let decision = actor.should_yield(store, "session_1")
  decision
  |> should.equal(Continue)

  actor.stop(store)
  process.sleep(100)
}

pub fn forced_pause_yield_test() {
  let assert Ok(store) = actor.start()

  actor.force_yield(store, "session_1", Pause("preempted by scheduler"))
  let decision = actor.should_yield(store, "session_1")

  decision
  |> should.equal(Pause("preempted by scheduler"))

  actor.stop(store)
  process.sleep(100)
}

pub fn forced_abort_yield_test() {
  let assert Ok(store) = actor.start()

  actor.force_yield(store, "session_1", Abort("budget exhausted"))
  let decision = actor.should_yield(store, "session_1")

  decision
  |> should.equal(Abort("budget exhausted"))

  actor.stop(store)
  process.sleep(100)
}

pub fn yield_consumed_after_check_test() {
  let assert Ok(store) = actor.start()

  actor.force_yield(store, "session_1", Pause("once"))

  // First call: consume the forced yield
  let decision1 = actor.should_yield(store, "session_1")
  decision1
  |> should.equal(Pause("once"))

  // Second call: decision consumed, back to Continue
  let decision2 = actor.should_yield(store, "session_1")
  decision2
  |> should.equal(Continue)

  actor.stop(store)
  process.sleep(100)
}

// ============================================================================
// resumption (retomada) Tests
// ============================================================================

pub fn resumption_from_checkpoint_test() {
  let assert Ok(store) = actor.start()

  // Simulate an agent saving a checkpoint when paused
  let messages = make_messages()
  let assert Ok(ckpt_id) =
    actor.save(store, "session_1", messages, None, dict.new())

  // Restore the checkpoint (simulates resumption)
  let assert Ok(checkpoint) = actor.restore(store, ckpt_id)

  // History is intact for resumption
  checkpoint.history
  |> should.not_equal([])

  checkpoint.session_id
  |> should.equal("session_1")

  actor.stop(store)
  process.sleep(100)
}

// ============================================================================
// delete Tests
// ============================================================================

pub fn delete_success_test() {
  let assert Ok(store) = actor.start()

  let assert Ok(ckpt_id) = actor.save(store, "session_1", [], None, dict.new())
  let assert Ok(_) = actor.delete(store, ckpt_id)

  // Verify deleted
  actor.restore(store, ckpt_id)
  |> should.be_error()

  actor.stop(store)
  process.sleep(100)
}

pub fn delete_not_found_fails_test() {
  let assert Ok(store) = actor.start()

  actor.delete(store, "nonexistent")
  |> should.be_error()

  actor.stop(store)
  process.sleep(100)
}

// ============================================================================
// list_for_session Tests
// ============================================================================

pub fn list_for_session_empty_test() {
  let assert Ok(store) = actor.start()

  actor.list_for_session(store, "session_1")
  |> should.equal([])

  actor.stop(store)
  process.sleep(100)
}

pub fn list_for_session_returns_session_checkpoints_test() {
  let assert Ok(store) = actor.start()

  let assert Ok(_) = actor.save(store, "session_1", [], None, dict.new())
  let assert Ok(_) = actor.save(store, "session_1", [], None, dict.new())
  let assert Ok(_) = actor.save(store, "session_2", [], None, dict.new())

  let checkpoints = actor.list_for_session(store, "session_1")
  checkpoints
  |> should.not_equal([])

  actor.stop(store)
  process.sleep(100)
}
