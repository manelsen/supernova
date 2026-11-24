//// After a turn with lembrar, the next message is checked for a
//// correction; only the answer is counted.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/llm/provider
import supernova/memory/correction
import supernova/memory/decision
import supernova/memory/gate
import supernova/memory/metrics
import supernova/memory/runtime

fn settings(p: String, seen: process.Subject(String)) -> runtime.Settings {
  runtime.Settings(
    transport: fn(_url, _headers, body) {
      process.send(seen, body)
      Ok(#(200, "{\"answers\":{\"corrige\":{\"noul\":" <> p <> "}}}"))
    },
    api_key: "k",
    gate_threshold: 0.1,
    gate_timeout_ms: 1000,
    recall_timeout_ms: 1000,
    charge: runtime.no_charge,
    within_budget: runtime.always_within,
  )
}

pub fn the_mark_is_taken_once_test() {
  correction.take_mark("telegram:9") |> should.be_false()
  correction.mark("telegram:9")
  correction.take_mark("telegram:9") |> should.be_true()
  correction.take_mark("telegram:9") |> should.be_false()
}

pub fn only_after_a_recall_test() {
  let seen = process.new_subject()
  correction.check(
    settings("0.9", seen),
    "telegram:8",
    Some("Dr. Lacerda."),
    "não!",
  )
  |> should.equal(None)
  process.receive(seen, 0) |> should.equal(Error(Nil))
}

pub fn a_correction_is_told_from_a_follow_up_test() {
  let seen = process.new_subject()
  correction.mark("telegram:7")
  correction.check(
    settings("0.91", seen),
    "telegram:7",
    Some("Você me disse que é o dr. Otávio Lacerda."),
    "não, eu falei que era o dr. Anselmo",
  )
  |> should.equal(Some(correction.Corrected))
  let assert Ok(body) = process.receive(seen, 1000)
  body |> string.contains("dr. Otávio Lacerda") |> should.be_true()
  body |> string.contains("dr. Anselmo") |> should.be_true()
  correction.mark("telegram:7")
  correction.check(
    settings("0.04", seen),
    "telegram:7",
    Some("Dr. Lacerda."),
    "isso, obrigada",
  )
  |> should.equal(Some(correction.NotCorrected))
  // No reply to compare with: nothing asked, the mark is gone anyway.
  correction.mark("telegram:7")
  correction.check(settings("0.9", seen), "telegram:7", None, "não")
  |> should.equal(None)
  correction.take_mark("telegram:7") |> should.be_false()
}

pub fn corrections_are_counted_without_text_test() {
  let report =
    gate.Report(
      verdict: gate.Quiet(0.01),
      gate_ms: 5,
      recall: None,
      recall_ms: 0,
      correction: Some(correction.Corrected),
    )
  metrics.turn_series(report)
  |> list.contains(
    metrics.Count(metrics.correction_total, 1, [
      #("result", "corrected"),
      #("reason", "none"),
    ]),
  )
  |> should.be_true()
  let failed =
    gate.Report(
      ..report,
      correction: Some(correction.Unknown(decision.TimedOut)),
    )
  metrics.turn_series(failed)
  |> list.contains(
    metrics.Count(metrics.correction_total, 1, [
      #("result", "failed"),
      #("reason", "timeout"),
    ]),
  )
  |> should.be_true()
}

/// Through the gate: a turn with lembrar marks the person; the next turn
/// compares her message with the agent's last reply.
pub fn the_gate_checks_the_turn_after_a_recall_test() {
  let seen = process.new_subject()
  correction.mark("telegram:6")
  let turn = [
    provider.system_message("núcleo"),
    provider.user_message("qual o nome do médico?"),
    provider.assistant_message("É o dr. Otávio Lacerda."),
    provider.user_message("não, era o dr. Anselmo"),
  ]
  let #(_, report) =
    gate.prepare_with(
      settings("0.92", seen),
      turn,
      "não, era o dr. Anselmo",
      "/nada",
      "telegram:6",
      -180,
    )
  let assert Some(gate.Report(correction: Some(correction.Corrected), ..)) =
    report
  let assert Ok(body) = process.receive(seen, 1000)
  body |> string.contains("É o dr. Otávio Lacerda.") |> should.be_true()
}

/// A Decision that fails leaves the correction unknown, counted as such.
pub fn a_failed_check_is_unknown_test() {
  let broken =
    runtime.Settings(
      ..settings("0.9", process.new_subject()),
      transport: fn(_, _, _) { Error("econnrefused") },
    )
  correction.ask(broken, "telegram:5", "Dr. Lacerda.", "não")
  |> should.equal(correction.Unknown(decision.Unreachable("econnrefused")))
  let report =
    gate.Report(
      verdict: gate.Skipped,
      gate_ms: 0,
      recall: None,
      recall_ms: 0,
      correction: Some(correction.NotCorrected),
    )
  metrics.turn_series(report)
  |> list.contains(
    metrics.Count(metrics.correction_total, 1, [
      #("result", "not_corrected"),
      #("reason", "none"),
    ]),
  )
  |> should.be_true()
}
