//// WorldModel — Pure Functions
////
//// Pure functions for fact management. No FFI, no side effects.
//// Functions take state and return new state + result + commands for the actor.
////
//// ## Usage
////
//// ```gleam
//// let #(state, result, cmds) = pure.assert_fact(state, "sky is blue", FactEntity, "agent_1", 0.9, now)
//// let #(state, result, cmds) = pure.retract(state, "fact_0", "outdated")
//// let facts = pure.query(state, FactPattern(fact_type: Some(FactEntity), ..))
//// let v = pure.version(state)
//// ```

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import supernova/core/world_model/types.{
  type Fact, type FactPattern, type FactType, type WorldModelCommand,
  type WorldModelState, Fact, NotifyChange, WorldModelState, WriteAssertAudit,
  WriteRetractAudit,
}

// ============================================================================
// Public API
// ============================================================================

/// Assert a new fact into the world model.
///
/// Returns `#(new_state, Ok(fact_id), commands)` on success.
/// Returns `#(state, Error(reason), [])` if confidence is out of range [0.0, 1.0].
pub fn assert_fact(
  state: WorldModelState,
  content: String,
  fact_type: FactType,
  author: String,
  confidence: Float,
  now: Int,
) -> #(WorldModelState, Result(String, String), List(WorldModelCommand)) {
  case confidence <. 0.0 || confidence >. 1.0 {
    True -> #(state, Error("Confidence must be between 0.0 and 1.0"), [])
    False -> {
      let fact_id = "fact_" <> int.to_string(state.next_id)
      let new_version = state.version + 1
      let fact =
        Fact(
          id: fact_id,
          fact_type: fact_type,
          content: content,
          author: author,
          confidence: confidence,
          version: new_version,
          created_at: now,
          tombstone: False,
        )
      let new_facts = dict.insert(state.facts, fact_id, fact)
      let new_state =
        WorldModelState(
          facts: new_facts,
          version: new_version,
          next_id: state.next_id + 1,
        )
      let commands = [
        NotifyChange(fact: fact),
        WriteAssertAudit(
          fact_id: fact_id,
          author: author,
          fact_type: types.fact_type_to_string(fact_type),
        ),
      ]
      #(new_state, Ok(fact_id), commands)
    }
  }
}

/// Retract a fact by ID (tombstone — does not delete).
///
/// Returns `#(new_state, Ok(Nil), commands)` on success.
/// Returns `#(state, Error(reason), [])` if not found or already retracted.
pub fn retract(
  state: WorldModelState,
  fact_id: String,
  reason: String,
) -> #(WorldModelState, Result(Nil, String), List(WorldModelCommand)) {
  case dict.get(state.facts, fact_id) {
    Error(_) -> #(state, Error("Fact not found: " <> fact_id), [])
    Ok(fact) ->
      case fact.tombstone {
        True -> #(state, Error("Fact already retracted: " <> fact_id), [])
        False -> {
          let new_version = state.version + 1
          let tombstoned = Fact(..fact, tombstone: True, version: new_version)
          let new_facts = dict.insert(state.facts, fact_id, tombstoned)
          let new_state =
            WorldModelState(..state, facts: new_facts, version: new_version)
          let commands = [
            NotifyChange(fact: tombstoned),
            WriteRetractAudit(fact_id: fact_id, reason: reason),
          ]
          #(new_state, Ok(Nil), commands)
        }
      }
  }
}

/// Query facts matching a pattern.
/// Only returns live facts (tombstone = False).
pub fn query(state: WorldModelState, pattern: FactPattern) -> List(Fact) {
  dict.values(state.facts)
  |> list.filter(fn(fact) { !fact.tombstone && matches_pattern(fact, pattern) })
}

/// Get the current version number.
/// Incremented on every assert or retract.
pub fn version(state: WorldModelState) -> Int {
  state.version
}

/// Check whether a fact matches the given pattern.
/// Used by query/2 and by the actor for subscriber fan-out.
pub fn matches_pattern(fact: Fact, pattern: FactPattern) -> Bool {
  let type_ok = case pattern.fact_type {
    None -> True
    Some(ft) -> fact.fact_type == ft
  }
  let author_ok = case pattern.author {
    None -> True
    Some(a) -> fact.author == a
  }
  let content_ok = case pattern.content_contains {
    None -> True
    Some(substr) -> string.contains(fact.content, substr)
  }
  type_ok && author_ok && content_ok
}
