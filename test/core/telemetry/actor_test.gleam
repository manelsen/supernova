//// Tests for the Telemetry Actor module
////
//// Integration tests — uses actors, no FFI assertions.

import gleam/dict
import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/telemetry/actor

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Lifecycle Tests
// ============================================================================

pub fn start_and_stop_test() {
  let assert Ok(tel) = actor.start()

  actor.stop(tel)
  |> should.equal(Nil)
}

pub fn start_with_capacity_test() {
  let assert Ok(tel) = actor.start_with_capacity(5)

  actor.stop(tel)
  |> should.equal(Nil)
}

// ============================================================================
// Emit Event Tests
// ============================================================================

pub fn emit_event_test() {
  let assert Ok(tel) = actor.start()

  let result =
    actor.emit_event(
      tel,
      "executor:start",
      "agent_1",
      dict.new(),
      dict.from_list([#("session_id", "s1")]),
    )

  case result {
    Ok(event) -> {
      event.name
      |> should.equal("executor:start")

      event.agent_id
      |> should.equal("agent_1")
    }
    Error(_) -> should.fail()
  }

  actor.stop(tel)
}

pub fn emit_multiple_events_test() {
  let assert Ok(tel) = actor.start()

  let assert Ok(_) =
    actor.emit_event(tel, "executor:start", "agent_1", dict.new(), dict.new())
  let assert Ok(_) =
    actor.emit_event(
      tel,
      "tool:start",
      "agent_1",
      dict.new(),
      dict.from_list([#("tool_name", "echo")]),
    )
  let assert Ok(_) =
    actor.emit_event(
      tel,
      "llm:request",
      "agent_2",
      dict.new(),
      dict.from_list([#("model", "gpt-4")]),
    )

  let events = actor.get_events(tel)
  list.length(events)
  |> should.equal(3)

  actor.stop(tel)
}

// ============================================================================
// Query Tests
// ============================================================================

pub fn get_events_by_agent_test() {
  let assert Ok(tel) = actor.start()

  let assert Ok(_) =
    actor.emit_event(tel, "e1", "agent_1", dict.new(), dict.new())
  let assert Ok(_) =
    actor.emit_event(tel, "e2", "agent_2", dict.new(), dict.new())
  let assert Ok(_) =
    actor.emit_event(tel, "e3", "agent_1", dict.new(), dict.new())

  let agent1_events = actor.get_events_by_agent(tel, "agent_1")
  list.length(agent1_events)
  |> should.equal(2)

  let agent2_events = actor.get_events_by_agent(tel, "agent_2")
  list.length(agent2_events)
  |> should.equal(1)

  actor.stop(tel)
}

pub fn get_events_by_prefix_test() {
  let assert Ok(tel) = actor.start()

  let assert Ok(_) =
    actor.emit_event(tel, "executor:start", "a", dict.new(), dict.new())
  let assert Ok(_) =
    actor.emit_event(tel, "tool:start", "a", dict.new(), dict.new())
  let assert Ok(_) =
    actor.emit_event(tel, "executor:stop", "a", dict.new(), dict.new())

  let executor_events = actor.get_events_by_prefix(tel, "executor:")
  list.length(executor_events)
  |> should.equal(2)

  let tool_events = actor.get_events_by_prefix(tel, "tool:")
  list.length(tool_events)
  |> should.equal(1)

  actor.stop(tel)
}

// ============================================================================
// All Mandatory Event Types Test
// ============================================================================

pub fn all_event_types_test() {
  let assert Ok(tel) = actor.start()

  // Emit one of each mandatory event type
  let event_names = [
    "executor:start",
    "executor:stop",
    "executor:exception",
    "tool:start",
    "tool:stop",
    "tool:exception",
    "llm:request",
    "llm:response",
    "llm:error",
    "session:created",
    "session:terminated",
    "subagent:spawned",
    "subagent:finished",
    "subagent:failed",
    "blackboard:post",
    "blackboard:fetch",
  ]

  list.each(event_names, fn(name) {
    let assert Ok(_) =
      actor.emit_event(tel, name, "agent_1", dict.new(), dict.new())
  })

  let events = actor.get_events(tel)
  list.length(events)
  |> should.equal(16)

  // Verify all event names are present
  let emitted_names =
    events
    |> list.map(fn(e) { e.name })
    |> list.sort(fn(a, b) { string.compare(a, b) })

  let sorted_expected =
    event_names
    |> list.sort(fn(a, b) { string.compare(a, b) })

  emitted_names
  |> should.equal(sorted_expected)

  actor.stop(tel)
}

import gleam/string
