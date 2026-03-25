//// MemoryFederation — Actor
////
//// OTP actor managing the federation pipeline from local memory to global WorldModel.
//// Delegates pure classification logic to the pure module, executes side effects
//// (WorldModel assertions, telemetry) here.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(wm) = world_model_actor.start()
//// let assert Ok(fed) = actor.start(config, wm)
//// let result = actor.federate(fed, "session_1", candidates)
//// // result.promoted — fact_ids now in WorldModel
//// // result.kept_local — count kept in local MEMORY.md
//// // result.rejected — count rejected entirely
//// actor.stop(fed)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import supernova/core/memory_federation/pure
import supernova/core/memory_federation/types.{
  type CandidateFact, type FederationConfig, type FederationResult,
  type FederationState, EmitTelemetry, FederationResult,
}
import supernova/core/world_model/actor as world_model_actor
import supernova/core/world_model/types as wm_types

/// Emit telemetry event (Erlang FFI).
@external(erlang, "supernova_telemetry_ffi", "write_event")
fn ffi_write_event(
  name: String,
  timestamp: Int,
  agent_id: String,
) -> Result(Nil, String)

/// Get current timestamp in milliseconds (Erlang FFI).
@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

// ============================================================================
// Types
// ============================================================================

/// Internal actor state: pure federation state + world model handle.
type ActorState {
  ActorState(
    /// Pure federation state (config, thresholds)
    federation: FederationState,
    /// Handle to the world model actor for asserting global facts
    world_model: world_model_actor.WorldModelHandle,
  )
}

/// Messages handled by the federation actor.
pub type FederationMessage {
  /// Run the federation pipeline for a session's candidate facts
  Federate(
    reply_to: Subject(FederationResult),
    session_id: String,
    candidates: List(CandidateFact),
  )
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running federation actor.
pub type FederationHandle =
  Subject(FederationMessage)

// ============================================================================
// Command Execution
// ============================================================================

/// Execute commands returned by pure functions.
fn execute_commands(commands: List(types.FederationCommand)) -> Nil {
  list.each(commands, fn(cmd) {
    case cmd {
      EmitTelemetry(name, measurements) -> {
        let agent_id = measurement_value(measurements, "agent_id")
        let _ = ffi_write_event(name, ffi_current_timestamp(), agent_id)
        Nil
      }
    }
  })
}

fn measurement_value(
  measurements: List(#(String, String)),
  key: String,
) -> String {
  case
    list.find(measurements, fn(entry) {
      let #(entry_key, _) = entry
      entry_key == key
    })
  {
    Ok(entry) -> {
      let #(_, value) = entry
      value
    }
    Error(_) -> "unknown"
  }
}

/// Promote a list of candidates to the WorldModel.
/// Returns the list of fact_ids assigned by WorldModel for successfully promoted facts.
fn promote_candidates(
  world_model: world_model_actor.WorldModelHandle,
  candidates: List(CandidateFact),
  agent_id: String,
) -> List(String) {
  list.filter_map(candidates, fn(candidate) {
    case
      world_model_actor.assert_fact(
        world_model,
        agent_id,
        candidate.content,
        wm_types.FactEntity,
        candidate.relevance,
      )
    {
      Ok(fact_id) -> Ok(fact_id)
      Error(_) -> Error(Nil)
    }
  })
}

// ============================================================================
// Actor Handler
// ============================================================================

/// Handle incoming messages and update state.
fn handle_message(
  actor_state: ActorState,
  message: FederationMessage,
) -> actor.Next(ActorState, FederationMessage) {
  case message {
    Federate(reply_to, session_id, candidates) -> {
      let #(new_federation, classification, cmds) =
        pure.federate(actor_state.federation, candidates, session_id)

      execute_commands(cmds)

      let promoted_ids =
        promote_candidates(
          actor_state.world_model,
          classification.to_promote,
          actor_state.federation.config.agent_id,
        )

      let result =
        FederationResult(
          promoted: promoted_ids,
          kept_local: classification.kept_local,
          rejected: classification.rejected,
        )

      actor.send(reply_to, result)
      actor.continue(ActorState(..actor_state, federation: new_federation))
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

/// Start the federation actor with the given config and world model handle.
pub fn start(
  config: FederationConfig,
  world_model: world_model_actor.WorldModelHandle,
) -> Result(FederationHandle, actor.StartError) {
  let initial =
    ActorState(
      federation: types.initial_state(config),
      world_model: world_model,
    )

  case
    actor.new(initial)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Run the federation pipeline for a session's candidate facts.
///
/// Classifies each candidate by relevance threshold:
/// - promoted: fact_ids of facts now in the global WorldModel
/// - kept_local: count of facts kept in local MEMORY.md
/// - rejected: count of facts discarded entirely
pub fn federate(
  handle: FederationHandle,
  session_id: String,
  candidates: List(CandidateFact),
) -> FederationResult {
  actor.call(handle, waiting: 5000, sending: Federate(_, session_id, candidates))
}

/// Stop the federation actor.
pub fn stop(handle: FederationHandle) -> Nil {
  actor.call(handle, waiting: 5000, sending: Stop)
}
