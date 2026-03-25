//// Tests for the Checkpoint Pure module
////
//// Pure tests — no I/O, no actors, no FFI.

import gleam/dict
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import supernova/core/checkpoint/pure
import supernova/core/checkpoint/types.{Abort, Continue, Pause}
import supernova/llm/provider

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helpers
// ============================================================================

fn empty_state() -> types.CheckpointState {
  types.initial_state()
}

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
// save Tests
// ============================================================================

pub fn save_returns_checkpoint_id_test() {
  let state = empty_state()
  let messages = make_messages()

  let #(_new_state, result) =
    pure.save(state, "session_1", messages, None, dict.new(), 1000)

  result
  |> should.be_ok()
}

pub fn save_increments_id_test() {
  let state = empty_state()
  let messages = make_messages()

  let assert #(state1, Ok(id1)) =
    pure.save(state, "session_1", messages, None, dict.new(), 1000)
  let assert #(_state2, Ok(id2)) =
    pure.save(state1, "session_1", messages, None, dict.new(), 2000)

  id1
  |> should.not_equal(id2)
}

pub fn save_with_pending_tool_test() {
  let state = empty_state()
  let messages = make_messages()
  let tool_call =
    provider.ToolCall(id: "tc_1", name: "get_weather", arguments: "{}")

  let #(_new_state, result) =
    pure.save(state, "session_1", messages, Some(tool_call), dict.new(), 1000)

  result
  |> should.be_ok()
}

pub fn save_with_metadata_test() {
  let state = empty_state()
  let metadata = dict.from_list([#("env", "test"), #("version", "1.0")])

  let #(_new_state, result) =
    pure.save(state, "session_1", [], None, metadata, 1000)

  result
  |> should.be_ok()
}

// ============================================================================
// restore Tests
// ============================================================================

pub fn restore_success_test() {
  let state = empty_state()
  let messages = make_messages()

  let assert #(state1, Ok(checkpoint_id)) =
    pure.save(state, "session_1", messages, None, dict.new(), 1000)

  let #(_state2, result) = pure.restore(state1, checkpoint_id)

  result
  |> should.be_ok()
}

pub fn restore_not_found_fails_test() {
  let state = empty_state()
  let #(_, result) = pure.restore(state, "nonexistent_ckpt")

  result
  |> should.be_error()
}

pub fn restore_preserves_history_test() {
  let state = empty_state()
  let messages = make_messages()

  let assert #(state1, Ok(checkpoint_id)) =
    pure.save(state, "session_1", messages, None, dict.new(), 1000)

  let assert #(_, Ok(checkpoint)) = pure.restore(state1, checkpoint_id)

  checkpoint.history
  |> should.equal(messages)
}

pub fn restore_preserves_session_id_test() {
  let state = empty_state()

  let assert #(state1, Ok(checkpoint_id)) =
    pure.save(state, "session_42", [], None, dict.new(), 1000)

  let assert #(_, Ok(checkpoint)) = pure.restore(state1, checkpoint_id)

  checkpoint.session_id
  |> should.equal("session_42")
}

pub fn restore_preserves_metadata_test() {
  let state = empty_state()
  let metadata = dict.from_list([#("key", "value")])

  let assert #(state1, Ok(checkpoint_id)) =
    pure.save(state, "session_1", [], None, metadata, 1000)

  let assert #(_, Ok(checkpoint)) = pure.restore(state1, checkpoint_id)

  checkpoint.context_metadata
  |> should.equal(metadata)
}

// ============================================================================
// should_yield Tests
// ============================================================================

pub fn should_yield_default_continue_test() {
  let state = empty_state()
  let #(_new_state, decision) = pure.should_yield(state, "session_1")

  decision
  |> should.equal(Continue)
}

pub fn should_yield_forced_pause_test() {
  let state = empty_state()
  let state1 = pure.force_yield(state, "session_1", Pause("scheduler"))

  let #(_new_state, decision) = pure.should_yield(state1, "session_1")

  decision
  |> should.equal(Pause("scheduler"))
}

pub fn should_yield_forced_abort_test() {
  let state = empty_state()
  let state1 = pure.force_yield(state, "session_1", Abort("budget exhausted"))

  let #(_new_state, decision) = pure.should_yield(state1, "session_1")

  decision
  |> should.equal(Abort("budget exhausted"))
}

pub fn should_yield_consumed_after_check_test() {
  let state = empty_state()
  let state1 = pure.force_yield(state, "session_1", Pause("once"))

  // First call: returns the forced decision
  let #(state2, decision1) = pure.should_yield(state1, "session_1")
  decision1
  |> should.equal(Pause("once"))

  // Second call: decision was consumed, returns Continue
  let #(_state3, decision2) = pure.should_yield(state2, "session_1")
  decision2
  |> should.equal(Continue)
}

pub fn should_yield_different_sessions_independent_test() {
  let state = empty_state()
  let state1 = pure.force_yield(state, "session_1", Pause("preempt"))

  // session_2 should still get Continue
  let #(_state2, decision) = pure.should_yield(state1, "session_2")
  decision
  |> should.equal(Continue)
}

// ============================================================================
// delete Tests
// ============================================================================

pub fn delete_success_test() {
  let state = empty_state()
  let assert #(state1, Ok(ckpt_id)) =
    pure.save(state, "session_1", [], None, dict.new(), 1000)

  let #(new_state, result) = pure.delete(state1, ckpt_id)

  result
  |> should.be_ok()

  // Verify it's gone
  let #(_, restore_result) = pure.restore(new_state, ckpt_id)
  restore_result
  |> should.be_error()
}

pub fn delete_not_found_fails_test() {
  let state = empty_state()
  let #(_, result) = pure.delete(state, "nonexistent")

  result
  |> should.be_error()
}

// ============================================================================
// list_for_session Tests
// ============================================================================

pub fn list_for_session_empty_test() {
  let state = empty_state()
  pure.list_for_session(state, "session_1")
  |> should.equal([])
}

pub fn list_for_session_returns_matching_test() {
  let state = empty_state()
  let #(state1, _) = pure.save(state, "session_1", [], None, dict.new(), 1000)
  let #(state2, _) = pure.save(state1, "session_1", [], None, dict.new(), 2000)
  let #(state3, _) = pure.save(state2, "session_2", [], None, dict.new(), 3000)
  let _ = state3

  let checkpoints = pure.list_for_session(state3, "session_1")
  checkpoints
  |> should.not_equal([])
}
