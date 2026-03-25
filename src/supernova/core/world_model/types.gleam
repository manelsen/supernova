//// WorldModel — Pure Types
////
//// Pure data structures for the shared, versioned fact repository.
//// No FFI, no side effects.
//// Facts are append-only with tombstones for retraction.

import gleam/dict.{type Dict}
import gleam/option.{type Option}

// ============================================================================
// Types
// ============================================================================

/// The semantic type of a fact.
pub type FactType {
  /// A real-world entity (person, place, system)
  FactEntity
  /// A decision made by an agent or the system
  FactDecision
  /// A constraint that must be respected
  FactConstraint
  /// A goal to be achieved
  FactGoal
}

/// A single fact in the world model.
/// Facts are immutable once asserted; retraction creates a new tombstoned version.
pub type Fact {
  Fact(
    /// Unique fact identifier (e.g., "fact_0", "fact_1")
    id: String,
    /// Semantic type of this fact
    fact_type: FactType,
    /// Natural language content of the fact
    content: String,
    /// Agent or system that asserted the fact
    author: String,
    /// Confidence level [0.0, 1.0]
    confidence: Float,
    /// World model version at time of this fact's last mutation
    version: Int,
    /// Timestamp when fact was first created (ms)
    created_at: Int,
    /// True if fact has been retracted (tombstoned); never deleted
    tombstone: Bool,
  )
}

/// A pattern for querying facts or subscribing to changes.
/// All fields are optional — None means "match any".
pub type FactPattern {
  FactPattern(
    /// Filter by fact type (None = any type)
    fact_type: Option(FactType),
    /// Filter by author (None = any author)
    author: Option(String),
    /// Filter facts whose content contains this substring (None = any content)
    content_contains: Option(String),
  )
}

/// Command pattern for I/O operations.
/// Pure functions return commands; the actor executes them.
pub type WorldModelCommand {
  /// Notify subscribers that a fact was asserted or retracted
  NotifyChange(fact: Fact)
  /// Write audit log for a fact assertion
  WriteAssertAudit(fact_id: String, author: String, fact_type: String)
  /// Write audit log for a fact retraction
  WriteRetractAudit(fact_id: String, reason: String)
}

/// The world model state maintained by the actor.
/// Append-only: facts are never deleted, only tombstoned.
pub type WorldModelState {
  WorldModelState(
    /// All facts indexed by fact_id (including tombstoned)
    facts: Dict(String, Fact),
    /// Monotonically increasing version counter — incremented on every mutation
    version: Int,
    /// Counter for generating unique fact IDs
    next_id: Int,
  )
}

// ============================================================================
// Default Values
// ============================================================================

/// Create an initial empty world model state.
pub fn initial_state() -> WorldModelState {
  WorldModelState(facts: dict.new(), version: 0, next_id: 0)
}

/// Convert a FactType to its string representation.
pub fn fact_type_to_string(ft: FactType) -> String {
  case ft {
    FactEntity -> "entity"
    FactDecision -> "decision"
    FactConstraint -> "constraint"
    FactGoal -> "goal"
  }
}

/// A pattern that matches all facts (no filters applied).
pub fn any_pattern() -> FactPattern {
  FactPattern(
    fact_type: option.None,
    author: option.None,
    content_contains: option.None,
  )
}
