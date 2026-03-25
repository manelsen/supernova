//// Telemetry — Actor
////
//// Singleton actor that collects standardized telemetry events.
//// Delegates pure logic to the pure module, executes side effects via FFI.
//// Integrates with ResourceLedger to feed events into the accounting system.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(telemetry) = actor.start()
//// let assert Ok(event) = actor.emit_event(telemetry, "executor:start", "agent_1", measurements, metadata)
//// actor.stop(telemetry)
//// ```

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import supernova/core/telemetry/pure
import supernova/core/telemetry/types.{
  type TelemetryCommand, type TelemetryEvent, type TelemetryState, FormatOutput,
  WriteToLedger,
}

// ============================================================================
// FFI — Timestamp and Output (Erlang)
// ============================================================================

/// Get current timestamp in milliseconds (Erlang FFI).
@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

/// Write telemetry event to output (Erlang FFI).
@external(erlang, "supernova_telemetry_ffi", "write_event")
fn ffi_write_event(
  name: String,
  timestamp: Int,
  agent_id: String,
) -> Result(Nil, String)

// ============================================================================
// Types
// ============================================================================

/// Messages that the telemetry actor handles.
pub type TelemetryMessage {
  /// Emit a telemetry event
  EmitEvent(
    reply_to: Subject(Result(TelemetryEvent, String)),
    name: String,
    agent_id: String,
    measurements: Dict(String, String),
    metadata: Dict(String, String),
  )
  /// Get recent events
  GetEvents(reply_to: Subject(List(TelemetryEvent)))
  /// Get events by agent
  GetEventsByAgent(reply_to: Subject(List(TelemetryEvent)), agent_id: String)
  /// Get events by name prefix
  GetEventsByPrefix(reply_to: Subject(List(TelemetryEvent)), prefix: String)
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running telemetry actor.
pub type Telemetry =
  Subject(TelemetryMessage)

// ============================================================================
// Actor Handler
// ============================================================================

/// Execute a list of commands returned by pure functions.
fn execute_commands(commands: List(TelemetryCommand)) -> Nil {
  list.each(commands, fn(cmd) {
    case cmd {
      WriteToLedger(agent_id, event_name, _measurements) -> {
        // Feed into ledger via FFI — the ledger actor handles the actual accounting
        let _ = ffi_write_event(event_name, ffi_current_timestamp(), agent_id)
        Nil
      }
      FormatOutput(event) -> {
        // Output event via FFI for monitoring/logging
        let _ = ffi_write_event(event.name, event.timestamp, event.agent_id)
        Nil
      }
    }
  })
}

/// Handle incoming messages and update state.
fn handle_message(
  state: TelemetryState,
  message: TelemetryMessage,
) -> actor.Next(TelemetryState, TelemetryMessage) {
  case message {
    EmitEvent(reply_to, name, agent_id, measurements, metadata) -> {
      let timestamp = ffi_current_timestamp()
      let #(new_state, commands, event) =
        pure.emit(state, name, timestamp, agent_id, measurements, metadata)
      execute_commands(commands)

      actor.send(reply_to, Ok(event))
      actor.continue(new_state)
    }

    GetEvents(reply_to) -> {
      let events = pure.get_events(state)
      actor.send(reply_to, events)
      actor.continue(state)
    }

    GetEventsByAgent(reply_to, agent_id) -> {
      let events = pure.get_events_by_agent(state, agent_id)
      actor.send(reply_to, events)
      actor.continue(state)
    }

    GetEventsByPrefix(reply_to, prefix) -> {
      let events = pure.get_events_by_prefix(state, prefix)
      actor.send(reply_to, events)
      actor.continue(state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start the telemetry actor.
pub fn start() -> Result(Telemetry, actor.StartError) {
  start_with_capacity(1000)
}

/// Start the telemetry actor with a custom event buffer capacity.
pub fn start_with_capacity(
  max_events: Int,
) -> Result(Telemetry, actor.StartError) {
  let initial_state = pure.initial_state(max_events)

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Emit a telemetry event.
pub fn emit_event(
  tel: Telemetry,
  name: String,
  agent_id: String,
  measurements: Dict(String, String),
  metadata: Dict(String, String),
) -> Result(TelemetryEvent, String) {
  actor.call(tel, waiting: 5000, sending: EmitEvent(
    _,
    name,
    agent_id,
    measurements,
    metadata,
  ))
}

/// Get all recent events.
pub fn get_events(tel: Telemetry) -> List(TelemetryEvent) {
  actor.call(tel, waiting: 5000, sending: GetEvents)
}

/// Get events for a specific agent.
pub fn get_events_by_agent(
  tel: Telemetry,
  agent_id: String,
) -> List(TelemetryEvent) {
  actor.call(tel, waiting: 5000, sending: GetEventsByAgent(_, agent_id))
}

/// Get events matching a name prefix.
pub fn get_events_by_prefix(
  tel: Telemetry,
  prefix: String,
) -> List(TelemetryEvent) {
  actor.call(tel, waiting: 5000, sending: GetEventsByPrefix(_, prefix))
}

/// Stop the telemetry actor.
pub fn stop(tel: Telemetry) -> Nil {
  actor.call(tel, waiting: 5000, sending: Stop)
}
