//// Tests for Telemetry module (backward compatibility).
////
//// Tests the pure module's emit and format_event functions.

import gleam/dict
import gleeunit/should
import supernova/core/telemetry/pure
import supernova/core/telemetry/types

pub fn emit_event_test() {
  let state = pure.initial_state(100)
  let measurements = dict.from_list([#("session_id", "s1"), #("depth", "0")])

  let #(_new_state, _commands, event) =
    pure.emit(
      state,
      "executor:start",
      1000,
      "agent_1",
      measurements,
      dict.new(),
    )

  event.name
  |> should.equal("executor:start")

  event.agent_id
  |> should.equal("agent_1")

  dict.get(event.measurements, "session_id")
  |> should.equal(Ok("s1"))
}

pub fn format_event_test() {
  let state = pure.initial_state(100)
  let measurements =
    dict.from_list([#("provider", "openai"), #("model", "gpt-4")])

  let #(_new_state, _commands, event) =
    pure.emit(state, "llm:request", 1000, "agent_1", measurements, dict.new())

  let formatted = pure.format_event(event)

  // Format includes timestamp and agent_id
  formatted
  |> should.equal(
    "[telemetry] llm:request ts=1000 agent=agent_1 model=gpt-4 provider=openai",
  )
}

pub fn event_without_measurements_test() {
  let state = pure.initial_state(100)

  let #(_new_state, _commands, event) =
    pure.emit(state, "session:created", 1000, "agent_1", dict.new(), dict.new())

  event.name
  |> should.equal("session:created")

  dict.size(event.measurements)
  |> should.equal(0)
}

pub fn event_type_to_string_test() {
  types.event_type_to_string(types.ExecutorStart)
  |> should.equal("executor:start")

  types.event_type_to_string(types.ToolStop)
  |> should.equal("tool:stop")

  types.event_type_to_string(types.LLMRequest)
  |> should.equal("llm:request")

  types.event_type_to_string(types.SessionCreated)
  |> should.equal("session:created")

  types.event_type_to_string(types.SubagentSpawned)
  |> should.equal("subagent:spawned")

  types.event_type_to_string(types.BlackboardPost)
  |> should.equal("blackboard:post")
}

pub fn valid_event_names_test() {
  let names = types.valid_event_names()

  list.length(names)
  |> should.equal(16)

  list.contains(names, "executor:start")
  |> should.equal(True)

  list.contains(names, "invalid:event")
  |> should.equal(False)
}

import gleam/list
