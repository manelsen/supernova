//// ContextInjector — Pure world model context injection.
////
//// Queries WorldModel for facts relevant to the current session topic
//// and prepends them to the prompt, respecting the token budget.
//// No FFI, no side effects — pure functions only.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import supernova/core/world_model/pure as wm_pure
import supernova/core/world_model/types.{
  type Fact, type WorldModelState, FactPattern,
}

// ============================================================================
// Public API
// ============================================================================

/// Inject relevant WorldModel facts into the prompt.
///
/// Queries facts whose content contains `session_topic` (case-sensitive).
/// Falls back to all live facts when no topic matches exist.
/// Respects `token_budget` (estimated as string length / 4).
///
/// Returns the original `prompt` prepended with a WorldModel section when
/// at least one fact fits the budget; otherwise returns `prompt` unchanged.
pub fn inject(
  world_state: WorldModelState,
  prompt: String,
  session_topic: String,
  token_budget: Int,
) -> String {
  // Query facts matching the session topic
  let topic_pattern =
    FactPattern(
      fact_type: None,
      author: None,
      content_contains: Some(session_topic),
    )
  let relevant = wm_pure.query(world_state, topic_pattern)

  // Fall back to all live facts when no topic match found
  let candidates = case relevant {
    [] -> wm_pure.query(world_state, types.any_pattern())
    _ -> relevant
  }

  // Select facts that fit within the token budget
  let selected = select_within_budget(candidates, token_budget, [])

  case selected {
    [] -> prompt
    _ -> {
      let facts_text =
        selected
        |> list.map(format_fact)
        |> string.join("\n")
      "## World Model Context\n" <> facts_text <> "\n\n" <> prompt
    }
  }
}

// ============================================================================
// Private helpers
// ============================================================================

/// Estimate tokens consumed by a string (chars / 4).
fn estimate_tokens(s: String) -> Int {
  string.length(s) / 4
}

/// Format a single fact for injection into the prompt.
fn format_fact(fact: Fact) -> String {
  "[" <> types.fact_type_to_string(fact.fact_type) <> "] " <> fact.content
}

/// Greedily select facts that fit within the remaining token budget.
/// Stops at the first fact that does not fit (preserves order).
fn select_within_budget(
  facts: List(Fact),
  remaining: Int,
  acc: List(Fact),
) -> List(Fact) {
  case facts {
    [] -> list.reverse(acc)
    [fact, ..rest] -> {
      let cost = estimate_tokens(format_fact(fact))
      case cost <= remaining {
        True -> select_within_budget(rest, remaining - cost, [fact, ..acc])
        False -> list.reverse(acc)
      }
    }
  }
}
