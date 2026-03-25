//// Checkpoint — Pure Types
////
//// Pure data structures for cooperative preemption via checkpointing.
//// No FFI, no side effects.
//// These types define the domain model for session checkpointing and yield decisions.

import gleam/dict.{type Dict}
import gleam/option.{type Option}
import supernova/llm/provider.{type ChatMessage, type ToolCall}

// ============================================================================
// Types
// ============================================================================

/// Yield decision returned by the scheduler.
pub type YieldDecision {
  /// Agent may continue executing
  Continue
  /// Agent should pause and save a checkpoint
  Pause(reason: String)
  /// Agent should abort execution immediately
  Abort(reason: String)
}

/// A saved execution checkpoint capturing full session state.
pub type Checkpoint {
  Checkpoint(
    /// Unique checkpoint identifier
    checkpoint_id: String,
    /// Session this checkpoint belongs to
    session_id: String,
    /// Full message history at the time of checkpoint
    history: List(ChatMessage),
    /// Pending tool call (if paused mid-tool), if any
    pending_tool: Option(ToolCall),
    /// Arbitrary metadata for context restoration
    context_metadata: Dict(String, String),
    /// Timestamp when checkpoint was created (ms)
    created_at: Int,
  )
}

/// Command pattern for I/O operations.
/// Pure functions return commands; the actor executes them.
pub type CheckpointCommand {
  /// Emit telemetry when a checkpoint is saved
  EmitCheckpointSaved(checkpoint_id: String, session_id: String)
  /// Emit telemetry when a checkpoint is restored
  EmitCheckpointRestored(checkpoint_id: String, session_id: String)
  /// Write audit log for yield decision
  WriteYieldAudit(session_id: String, decision: String, reason: String)
}

/// The checkpoint store state maintained by the actor.
pub type CheckpointState {
  CheckpointState(
    /// Saved checkpoints indexed by checkpoint_id
    checkpoints: Dict(String, Checkpoint),
    /// Forced yield decisions indexed by session_id (for testing/preemption)
    forced_yields: Dict(String, YieldDecision),
    /// Counter for generating unique checkpoint IDs
    next_id: Int,
  )
}

// ============================================================================
// Default Values
// ============================================================================

/// Create an initial empty checkpoint state.
pub fn initial_state() -> CheckpointState {
  CheckpointState(
    checkpoints: dict.new(),
    forced_yields: dict.new(),
    next_id: 0,
  )
}
