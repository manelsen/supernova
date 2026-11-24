//// What the memory did, for /metrics (docs/prd/PRD-M-memoria.md, 6.6).
////
//// Counters and histograms only: no label carries text, a principal or a
//// chat (I7). The series are computed by pure functions, so tests check
//// them without a metrics actor.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import supernova/memory/decision
import supernova/memory/gate
import supernova/memory/recall
import supernova/metrics/record

pub type Series {
  Count(name: String, amount: Int, labels: List(#(String, String)))
  Duration(name: String, ms: Int, labels: List(#(String, String)))
}

pub const gate_total = "supernova_memory_gate_total"

pub const gate_seconds = "supernova_memory_gate_seconds"

pub const recall_total = "supernova_memory_recall_total"

pub const recall_seconds = "supernova_memory_recall_seconds"

pub const decision_tokens_total = "supernova_memory_decision_tokens_total"

pub const embed_tokens_total = "supernova_memory_embed_tokens_total"

pub const cost_microusd_total = "supernova_memory_cost_microusd_total"

/// One turn's gate and pre-search.
pub fn turn_series(report: gate.Report) -> List(Series) {
  let #(result, reason) = case report.verdict {
    gate.Fired(_) -> #("fired", "none")
    gate.Quiet(_) -> #("quiet", "none")
    gate.Skipped -> #("skipped", "none")
    gate.Failed(error) -> #("failed", failure(error))
  }
  let gate = case report.verdict {
    gate.Skipped -> [
      Count(gate_total, 1, [#("result", result), #("reason", reason)]),
    ]
    _ -> [
      Count(gate_total, 1, [#("result", result), #("reason", reason)]),
      Duration(gate_seconds, report.gate_ms, []),
    ]
  }
  let gate_tokens = case report.verdict {
    gate.Fired(_) | gate.Quiet(_) -> gate_cost_series()
    _ -> []
  }
  let recalled = case report.recall {
    Some(outcome) -> recall_series(outcome, "prefetch", report.recall_ms)
    None -> []
  }
  list.flatten([gate, gate_tokens, recalled])
}

/// One `lembrar`, by the pre-search or by the agent.
pub fn recall_series(
  outcome: recall.Outcome,
  origin: String,
  elapsed_ms: Int,
) -> List(Series) {
  let band = case outcome.probability {
    None -> "none"
    Some(p) ->
      case p <. recall.unlikely_below, p <. recall.likely_from {
        True, _ -> "unlikely"
        False, True -> "maybe"
        False, False -> "likely"
      }
  }
  let failed = case outcome.failure {
    None -> "none"
    Some(error) -> failure(error)
  }
  let embed_tokens = outcome.embedded_chars / 2
  [
    Count(recall_total, 1, [
      #("origin", origin),
      #("band", band),
      #("failure", failed),
    ]),
    Duration(recall_seconds, elapsed_ms, [#("origin", origin)]),
    Count(decision_tokens_total, outcome.decision_tokens, []),
    Count(embed_tokens_total, embed_tokens, []),
    Count(
      cost_microusd_total,
      microusd(outcome.decision_tokens, decision.decision_usd_per_million)
        + microusd(embed_tokens, decision.embed_usd_per_million),
      [],
    ),
  ]
}

/// The gate's input is one short message: ~100 tokens, recorded as such.
fn gate_cost_series() -> List(Series) {
  [
    Count(decision_tokens_total, 100, []),
    Count(
      cost_microusd_total,
      microusd(100, decision.decision_usd_per_million),
      [],
    ),
  ]
}

/// US$ per million tokens × tokens, in micro-US$ (millionths): the price
/// itself.
fn microusd(tokens: Int, usd_per_million: Float) -> Int {
  float.round(int.to_float(tokens) *. usd_per_million)
}

fn failure(error: decision.DecisionError) -> String {
  case error {
    decision.TimedOut -> "timeout"
    decision.Blocked(_) -> "blocked"
    decision.HttpError(..) -> "http"
    decision.Unreachable(_) -> "unreachable"
    decision.BadResponse(_) -> "bad_response"
  }
}

pub fn record_turn(report: Option(gate.Report)) -> Nil {
  case report {
    Some(r) -> emit(turn_series(r))
    None -> Nil
  }
}

pub fn record_recall(outcome: recall.Outcome, origin: String, ms: Int) -> Nil {
  emit(recall_series(outcome, origin, ms))
}

fn emit(series: List(Series)) -> Nil {
  list.each(series, fn(s) {
    case s {
      Count(name, amount, labels) -> record.count_by(name, amount, labels)
      Duration(name, ms, labels) -> record.duration_ms(name, ms, labels)
    }
  })
}
