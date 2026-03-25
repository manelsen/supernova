//// MemoryFederation — Pure Functions
////
//// Pure functions for the federation pipeline. No FFI, no side effects.
//// Functions take state and return new state + classification + commands.
////
//// ## Usage
////
//// ```gleam
//// let candidates = [CandidateFact(content: "sky is blue", relevance: 0.9, session_id: "s1", tags: [])]
//// let #(state, classification, cmds) = pure.federate(state, candidates, "s1")
//// // classification.to_promote contains high-relevance facts for WorldModel
//// // classification.kept_local is the count of moderate-relevance facts
//// // classification.rejected is the count of low-relevance facts
//// ```

import gleam/int
import gleam/list
import supernova/core/memory_federation/types.{
  type CandidateFact, type ClassificationResult, type FederationCommand,
  type FederationState, ClassificationResult, EmitTelemetry,
}

// ============================================================================
// Public API
// ============================================================================

/// Classify candidates for federation.
///
/// Partitions candidates into three buckets based on the configured thresholds:
/// - relevance >= global_threshold → to_promote (will be asserted to WorldModel)
/// - local_threshold <= relevance < global_threshold → kept_local
/// - relevance < local_threshold → rejected
///
/// Returns `#(new_state, ClassificationResult, commands)`.
pub fn federate(
  state: FederationState,
  candidates: List(CandidateFact),
  session_id: String,
) -> #(FederationState, ClassificationResult, List(FederationCommand)) {
  let #(to_promote, remaining) =
    list.partition(candidates, fn(c) {
      c.relevance >=. state.config.global_threshold
    })

  let #(kept, rejected) =
    list.partition(remaining, fn(c) {
      c.relevance >=. state.config.local_threshold
    })

  let result =
    ClassificationResult(
      to_promote: to_promote,
      kept_local: list.length(kept),
      rejected: list.length(rejected),
    )

  let cmds = [
    EmitTelemetry("federation:federate", [
      #("session_id", session_id),
      #("promoted", int.to_string(list.length(to_promote))),
      #("kept_local", int.to_string(list.length(kept))),
      #("rejected", int.to_string(list.length(rejected))),
    ]),
  ]

  #(state, result, cmds)
}
