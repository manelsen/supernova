//// Checkpoint — Actor
////
//// Actor that manages the checkpoint store and yield decisions.
//// Delegates pure logic to the pure module, executes side effects via FFI.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(store) = actor.start()
//// let assert Ok(ckpt_id) = actor.save(store, "session_1", messages, None, dict.new())
//// let assert Ok(checkpoint) = actor.restore(store, ckpt_id)
//// actor.force_yield(store, "session_1", Pause("scheduler requested"))
//// let decision = actor.should_yield(store, "session_1")
//// actor.stop(store)
//// ```

import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import supernova/core/checkpoint/pure
import supernova/core/checkpoint/types.{
  type Checkpoint, type CheckpointState, type YieldDecision,
}
import supernova/llm/provider.{type ChatMessage, type ToolCall}

// ============================================================================
// FFI — Timestamp (Erlang)
// ============================================================================

/// Get current timestamp in milliseconds (Erlang FFI).
@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

// ============================================================================
// Types
// ============================================================================

/// Messages that the checkpoint actor handles.
pub type CheckpointMessage {
  /// Save a new checkpoint
  Save(
    reply_to: Subject(Result(String, String)),
    session_id: String,
    history: List(ChatMessage),
    pending_tool: Option(ToolCall),
    metadata: dict.Dict(String, String),
  )
  /// Restore a checkpoint by ID
  Restore(reply_to: Subject(Result(Checkpoint, String)), checkpoint_id: String)
  /// Check if a session should yield
  ShouldYield(reply_to: Subject(YieldDecision), session_id: String)
  /// Force a yield decision for a session (for testing/preemption)
  ForceYield(
    reply_to: Subject(Nil),
    session_id: String,
    decision: YieldDecision,
  )
  /// Delete a checkpoint by ID
  Delete(reply_to: Subject(Result(Nil, String)), checkpoint_id: String)
  /// List checkpoints for a session
  ListForSession(reply_to: Subject(List(Checkpoint)), session_id: String)
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running checkpoint actor.
pub type CheckpointHandle =
  Subject(CheckpointMessage)

// ============================================================================
// Actor Handler
// ============================================================================

/// Handle incoming messages and update state.
fn handle_message(
  state: CheckpointState,
  message: CheckpointMessage,
) -> actor.Next(CheckpointState, CheckpointMessage) {
  case message {
    Save(reply_to, session_id, history, pending_tool, metadata) -> {
      let now = ffi_current_timestamp()
      let #(new_state, result) =
        pure.save(state, session_id, history, pending_tool, metadata, now)
      execute_commands([])
      actor.send(reply_to, result)
      actor.continue(new_state)
    }

    Restore(reply_to, checkpoint_id) -> {
      let #(new_state, result) = pure.restore(state, checkpoint_id)
      execute_commands([])
      actor.send(reply_to, result)
      actor.continue(new_state)
    }

    ShouldYield(reply_to, session_id) -> {
      let #(new_state, decision) = pure.should_yield(state, session_id)
      actor.send(reply_to, decision)
      actor.continue(new_state)
    }

    ForceYield(reply_to, session_id, decision) -> {
      let new_state = pure.force_yield(state, session_id, decision)
      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    Delete(reply_to, checkpoint_id) -> {
      let #(new_state, result) = pure.delete(state, checkpoint_id)
      actor.send(reply_to, result)
      actor.continue(new_state)
    }

    ListForSession(reply_to, session_id) -> {
      let checkpoints = pure.list_for_session(state, session_id)
      actor.send(reply_to, checkpoints)
      actor.continue(state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

/// Execute commands returned by pure functions.
fn execute_commands(commands: List(types.CheckpointCommand)) -> Nil {
  list.each(commands, fn(_cmd) {
    // TODO: Integrate with telemetry/audit systems when available
    Nil
  })
}

// ============================================================================
// Public API
// ============================================================================

/// Start the checkpoint actor.
pub fn start() -> Result(CheckpointHandle, actor.StartError) {
  let initial_state = types.initial_state()

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Save a new checkpoint for the given session.
pub fn save(
  store: CheckpointHandle,
  session_id: String,
  history: List(ChatMessage),
  pending_tool: Option(ToolCall),
  metadata: dict.Dict(String, String),
) -> Result(String, String) {
  actor.call(store, waiting: 5000, sending: Save(
    _,
    session_id,
    history,
    pending_tool,
    metadata,
  ))
}

/// Restore a checkpoint by its ID.
pub fn restore(
  store: CheckpointHandle,
  checkpoint_id: String,
) -> Result(Checkpoint, String) {
  actor.call(store, waiting: 5000, sending: Restore(_, checkpoint_id))
}

/// Check whether the given session should yield execution.
/// Consumes any forced yield decision (one-shot).
pub fn should_yield(
  store: CheckpointHandle,
  session_id: String,
) -> YieldDecision {
  actor.call(store, waiting: 5000, sending: ShouldYield(_, session_id))
}

/// Force a yield decision for a session (for testing and scheduler preemption).
pub fn force_yield(
  store: CheckpointHandle,
  session_id: String,
  decision: YieldDecision,
) -> Nil {
  actor.call(store, waiting: 5000, sending: ForceYield(_, session_id, decision))
}

/// Delete a checkpoint by its ID.
pub fn delete(
  store: CheckpointHandle,
  checkpoint_id: String,
) -> Result(Nil, String) {
  actor.call(store, waiting: 5000, sending: Delete(_, checkpoint_id))
}

/// List all checkpoints for a session.
pub fn list_for_session(
  store: CheckpointHandle,
  session_id: String,
) -> List(Checkpoint) {
  actor.call(store, waiting: 5000, sending: ListForSession(_, session_id))
}

/// Stop the checkpoint actor.
pub fn stop(store: CheckpointHandle) -> Nil {
  actor.call(store, waiting: 5000, sending: Stop)
}
