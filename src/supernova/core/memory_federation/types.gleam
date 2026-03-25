//// MemoryFederation — Pure Types
////
//// Pure data structures for the memory federation system.
//// No FFI, no side effects.
////
//// Federation promotes locally-relevant facts to the global world model,
//// enabling knowledge sharing across agents.

// ============================================================================
// Types
// ============================================================================

/// A fact candidate extracted from local memory for federation classification.
pub type CandidateFact {
  CandidateFact(
    /// The fact content to potentially promote
    content: String,
    /// Relevance score [0.0, 1.0] — determines promotion vs retention vs rejection
    relevance: Float,
    /// Session from which this fact originated
    session_id: String,
    /// Optional tags for categorization
    tags: List(String),
  )
}

/// The result of a federation operation.
/// Returned after promoting local facts to the global world model.
pub type FederationResult {
  FederationResult(
    /// World model fact_ids for promoted facts (assigned by WorldModel)
    promoted: List(String),
    /// Count of facts kept in local memory (below global threshold but above local threshold)
    kept_local: Int,
    /// Count of facts rejected entirely (below local threshold)
    rejected: Int,
  )
}

/// Configuration for the federation pipeline.
/// Thresholds are per-agent and control promotion behaviour.
pub type FederationConfig {
  FederationConfig(
    /// Relevance >= this → promote to global WorldModel
    global_threshold: Float,
    /// Relevance >= this (but < global_threshold) → keep in local MEMORY.md
    /// Relevance < this → reject entirely
    local_threshold: Float,
    /// Agent ID used as author when asserting facts to WorldModel
    agent_id: String,
  )
}

/// The federation state maintained by the actor.
pub type FederationState {
  FederationState(
    /// Per-agent configuration (thresholds and agent identity)
    config: FederationConfig,
  )
}

/// Classification result from pure.federate/3.
/// Separates candidates into promotion, retention, and rejection buckets.
pub type ClassificationResult {
  ClassificationResult(
    /// Facts to promote to WorldModel (relevance >= global_threshold)
    to_promote: List(CandidateFact),
    /// Count of facts kept in local memory
    kept_local: Int,
    /// Count of facts rejected entirely
    rejected: Int,
  )
}

/// Command pattern for I/O operations.
/// Pure functions return commands; the actor executes them.
pub type FederationCommand {
  /// Emit a telemetry event for observability
  EmitTelemetry(name: String, measurements: List(#(String, String)))
}

// ============================================================================
// Default Values
// ============================================================================

/// Create an initial federation state with the given config.
pub fn initial_state(config: FederationConfig) -> FederationState {
  FederationState(config: config)
}

/// Default configuration for an agent.
/// global_threshold = 0.7 — promotes high-confidence broadly relevant facts.
/// local_threshold  = 0.3 — keeps moderate-relevance facts locally.
pub fn default_config(agent_id: String) -> FederationConfig {
  FederationConfig(
    global_threshold: 0.7,
    local_threshold: 0.3,
    agent_id: agent_id,
  )
}
