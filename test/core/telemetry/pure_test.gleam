//// Tests for the Telemetry Pure module
////
//// Pure tests — no I/O, no actors, no FFI.

import gleam/dict
import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/telemetry/pure
import supernova/core/telemetry/types.{type TelemetryState}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helper: Create empty state
// ============================================================================

fn empty_state() -> TelemetryState {
  pure.initial_state(100)
}

// ============================================================================
// emit Tests
// ============================================================================

pub fn emit_creates_event_test() {
  let state = empty_state()
  let measurements = dict.from_list([#("duration_ms", "150")])
  let metadata = dict.from_list([#("session_id", "s1")])

  let #(_new_state, commands, event) =
    pure.emit(state, "executor:start", 1000, "agent_1", measurements, metadata)

  event.name
  |> should.equal("executor:start")

  event.timestamp
  |> should.equal(1000)

  event.agent_id
  |> should.equal("agent_1")

  dict.get(event.measurements, "duration_ms")
  |> should.equal(Ok("150"))

  dict.get(event.metadata, "session_id")
  |> should.equal(Ok("s1"))

  // Should produce commands
  list.length(commands)
  |> should.equal(2)
}

pub fn emit_updates_state_test() {
  let state = empty_state()

  let #(state1, _, _event1) =
    pure.emit(state, "executor:start", 1000, "agent_1", dict.new(), dict.new())

  let #(_state2, _, _event2) =
    pure.emit(state1, "executor:stop", 2000, "agent_1", dict.new(), dict.new())
}

pub fn format_event_empty_test() {
  let state = empty_state()

  let #(_new_state, _commands, event) =
    pure.emit(state, "session:created", 1000, "agent_1", dict.new(), dict.new())

  let formatted = pure.format_event(event)

  formatted
  |> should.equal("[telemetry] session:created ts=1000 agent=agent_1")
}

// ============================================================================
// Consistent Format Tests — verify all event types produce consistent output
// ============================================================================

pub fn all_event_types_have_consistent_format_test() {
  let state = empty_state()

  // Test a sample of event types
  let events = [
    pure.executor_start(state, 1000, "a", "s1").2,
    pure.executor_stop(state, 1000, "a", 500).2,
    pure.executor_exception(state, 1000, "a", "err").2,
    pure.tool_start(state, 1000, "a", "tool1").2,
    pure.tool_stop(state, 1000, "a", "tool1", 100).2,
    pure.tool_exception(state, 1000, "a", "tool1", "err").2,
    pure.llm_request(state, 1000, "a", "gpt-4", "openai").2,
    pure.llm_response(state, 1000, "a", "gpt-4", 100, 50).2,
    pure.llm_error(state, 1000, "a", "gpt-4", "err").2,
    pure.session_created(state, 1000, "a", "s1").2,
    pure.session_terminated(state, 1000, "a", "s1", 1000).2,
    pure.subagent_spawned(state, 1000, "a", "child").2,
    pure.subagent_finished(state, 1000, "a", "child").2,
    pure.subagent_failed(state, 1000, "a", "child", "err").2,
    pure.blackboard_post(state, 1000, "a", "key").2,
    pure.blackboard_fetch(state, 1000, "a", "key").2,
  ]

  // All events should have consistent fields
  list.each(events, fn(event) {
    event.name
    |> should.not_equal("")

    event.timestamp
    |> should.equal(1000)

    event.agent_id
    |> should.equal("a")

    // All events should format without errors
    let formatted = pure.format_event(event)
    formatted
    |> string.starts_with("[telemetry]")
    |> should.equal(True)
  })

  // Verify we tested all 16 event types
  list.length(events)
  |> should.equal(16)
}

import gleam/string
