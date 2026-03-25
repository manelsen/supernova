//// Checkpoint — Pure Functions
////
//// Pure functions for checkpoint management. No FFI, no side effects.
//// Functions take state and return new state + result for the actor to execute.
////
//// ## Usage
////
//// ```gleam
//// let #(state, result) = pure.save(state, "session_1", messages, None, dict.new(), now)
//// let #(state, result) = pure.restore(state, "ckpt_0")
//// let #(state, decision) = pure.should_yield(state, "session_1")
//// ```

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option}
import supernova/core/checkpoint/types.{
  type Checkpoint, type CheckpointCommand, type CheckpointState,
  type YieldDecision, Checkpoint, CheckpointState, Continue,
  EmitCheckpointRestored, EmitCheckpointSaved, WriteYieldAudit,
}
import supernova/llm/provider.{type ChatMessage, type ToolCall}

// ============================================================================
// Public API
// ============================================================================

/// Save a checkpoint for the given session.
///
/// Returns `#(new_state, Ok(checkpoint_id))` on success.
pub fn save(
  state: CheckpointState,
  session_id: String,
  history: List(ChatMessage),
  pending_tool: Option(ToolCall),
  metadata: dict.Dict(String, String),
  now: Int,
) -> #(CheckpointState, Result(String, String), List(CheckpointCommand)) {
  let checkpoint_id = "ckpt_" <> int.to_string(state.next_id)
  let cp =
    Checkpoint(
      checkpoint_id: checkpoint_id,
      session_id: session_id,
      history: history,
      pending_tool: pending_tool,
      context_metadata: metadata,
      created_at: now,
    )
  let new_checkpoints = dict.insert(state.checkpoints, checkpoint_id, cp)
  let new_state =
    CheckpointState(
      ..state,
      checkpoints: new_checkpoints,
      next_id: state.next_id + 1,
    )
  let commands = [
    EmitCheckpointSaved(checkpoint_id: checkpoint_id, session_id: session_id),
  ]
  #(new_state, Ok(checkpoint_id), commands)
}

/// Restore a checkpoint by its ID.
///
/// Returns `#(state, Ok(checkpoint))` on success.
/// Returns `#(state, Error("Checkpoint not found: ..."))` if not found.
pub fn restore(
  state: CheckpointState,
  checkpoint_id: String,
) -> #(CheckpointState, Result(Checkpoint, String), List(CheckpointCommand)) {
  case dict.get(state.checkpoints, checkpoint_id) {
    Ok(cp) -> #(state, Ok(cp), [
      EmitCheckpointRestored(
        checkpoint_id: checkpoint_id,
        session_id: cp.session_id,
      ),
    ])
    Error(_) -> #(state, Error("Checkpoint not found: " <> checkpoint_id), [])
  }
}

/// Check whether the given session should yield execution.
///
/// Consults the forced_yields dict (set by force_yield/3 or by the actor
/// after consulting KernelScheduler). One-shot: the decision is consumed.
///
/// Returns `#(new_state, Continue)` if no yield is forced.
pub fn should_yield(
  state: CheckpointState,
  session_id: String,
) -> #(CheckpointState, YieldDecision, List(CheckpointCommand)) {
  case dict.get(state.forced_yields, session_id) {
    Ok(decision) -> {
      // Consume the forced yield (one-shot)
      let new_yields = dict.delete(state.forced_yields, session_id)
      let new_state = CheckpointState(..state, forced_yields: new_yields)
      let #(decision_name, reason) = decision_to_audit_parts(decision)
      #(new_state, decision, [
        WriteYieldAudit(
          session_id: session_id,
          decision: decision_name,
          reason:,
        ),
      ])
    }
    Error(_) -> #(state, Continue, [])
  }
}

/// Force a yield decision for a session (for testing and preemption).
///
/// The decision will be consumed by the next `should_yield/2` call
/// for the same session_id.
pub fn force_yield(
  state: CheckpointState,
  session_id: String,
  decision: YieldDecision,
) -> CheckpointState {
  let new_yields = dict.insert(state.forced_yields, session_id, decision)
  CheckpointState(..state, forced_yields: new_yields)
}

/// Delete a checkpoint by its ID.
///
/// Returns `#(new_state, Ok(Nil))` on success.
/// Returns `#(state, Error("Checkpoint not found: ..."))` if not found.
pub fn delete(
  state: CheckpointState,
  checkpoint_id: String,
) -> #(CheckpointState, Result(Nil, String)) {
  case dict.get(state.checkpoints, checkpoint_id) {
    Ok(_) -> {
      let new_checkpoints = dict.delete(state.checkpoints, checkpoint_id)
      let new_state = CheckpointState(..state, checkpoints: new_checkpoints)
      #(new_state, Ok(Nil))
    }
    Error(_) -> #(state, Error("Checkpoint not found: " <> checkpoint_id))
  }
}

/// List all checkpoints for a given session.
pub fn list_for_session(
  state: CheckpointState,
  session_id: String,
) -> List(Checkpoint) {
  dict.values(state.checkpoints)
  |> list.filter(fn(cp) { cp.session_id == session_id })
}

fn decision_to_audit_parts(decision: YieldDecision) -> #(String, String) {
  case decision {
    Continue -> #("continue", "")
    types.Pause(reason) -> #("pause", reason)
    types.Abort(reason) -> #("abort", reason)
  }
}
