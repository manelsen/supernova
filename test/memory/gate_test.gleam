//// The gate asks only about the message, never holds a turn past its
//// timeout (I1), lets the turn go on when the Decision fails (I6), adds
//// the pre-search when it fires, and leaves the turn alone otherwise (I5).

import exception
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/core/session/history_store.{HistoryStore, StoredMessage}
import supernova/llm/provider
import supernova/memory/decision
import supernova/memory/gate
import supernova/memory/metrics
import supernova/memory/runtime
import test_workspace

const base = 1_795_694_400_000

fn settings(transport: decision.Transport) -> runtime.Settings {
  runtime.Settings(
    transport: transport,
    api_key: "k",
    gate_threshold: 0.1,
    gate_timeout_ms: 200,
    recall_timeout_ms: 5000,
    charge: runtime.no_charge,
    within_budget: runtime.always_within,
  )
}

/// The gate answers `past`; lembrar finds excerpt 1 at 0.9.
fn fake(past: String, seen: process.Subject(String)) -> decision.Transport {
  fn(url, _headers, body) {
    process.send(seen, body)
    case url == decision.embed_url, string.contains(body, "\"passado\"") {
      True, _ -> Ok(#(200, "{\"embedding\":{\"values\":[1,0]}}"))
      False, True ->
        Ok(#(200, "{\"answers\":{\"passado\":{\"noul\":" <> past <> "}}}"))
      False, False ->
        Ok(#(
          200,
          "{\"answers\":{\"falado\":{\"noul\":0.9},\"t1\":{\"noul\":0.9}}}",
        ))
    }
  }
}

pub fn the_gate_asks_about_the_message_only_test() {
  let seen = process.new_subject()
  gate.ask(settings(fake("0.93", seen)), "qual o nome do cardiologista?")
  |> should.equal(gate.Fired(0.93))
  let assert Ok(body) = process.receive(seen, 1000)
  body |> string.contains(gate.question) |> should.be_true()
  body
  |> string.contains("qual o nome do cardiologista?")
  |> should.be_true()
  gate.ask(settings(fake("0.02", seen)), "bom dia!")
  |> should.equal(gate.Quiet(0.02))
}

pub fn commands_and_empty_messages_skip_the_gate_test() {
  let seen = process.new_subject()
  gate.ask(settings(fake("0.9", seen)), "/esquecer")
  |> should.equal(gate.Skipped)
  gate.ask(settings(fake("0.9", seen)), "   ") |> should.equal(gate.Skipped)
  process.receive(seen, 0) |> should.equal(Error(Nil))
}

/// A Decision that never answers holds the turn only for the timeout.
pub fn the_gate_never_holds_a_turn_past_its_timeout_test() {
  let never = fn(_url, _headers, _body) {
    let nothing = process.new_subject()
    let _ = process.receive(nothing, 60_000)
    Ok(#(200, "{}"))
  }
  gate.ask(settings(never), "lembra do médico?")
  |> should.equal(gate.Failed(decision.TimedOut))
}

fn with_dir(body: fn(String) -> a) -> a {
  let dir = test_workspace.create_temp_dir("gate")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  body(dir)
}

fn turn() -> List(provider.ChatMessage) {
  [
    provider.system_message("núcleo"),
    provider.user_message("lembra do médico?"),
  ]
}

pub fn a_fired_gate_adds_the_pre_search_test() {
  use dir <- with_dir
  let store = HistoryStore(data_dir: dir, limit: 100)
  let assert Ok(Nil) =
    history_store.append(store, "telegram:42:42", [
      StoredMessage(role: "user", content: "é o dr. Otávio Lacerda", at: base),
    ])
  let seen = process.new_subject()
  let #(messages, report) =
    gate.prepare_with(
      settings(fake("0.93", seen)),
      turn(),
      "lembra do médico?",
      dir,
      "telegram:42",
      -180,
    )
  let assert [_, _, call, result] = messages
  call.role |> should.equal("assistant")
  let assert Some([tool_call]) = call.tool_calls
  tool_call.id |> should.equal(gate.call_id)
  tool_call.name |> should.equal("lembrar")
  tool_call.arguments
  |> should.equal("{\"assunto\":\"lembra do médico?\"}")
  result.role |> should.equal("tool")
  result.tool_call_id |> should.equal(Some(gate.call_id))
  result.content |> string.contains("dr. Otávio Lacerda") |> should.be_true()
  let assert Some(gate.Report(verdict: gate.Fired(_), recall: Some(_), ..)) =
    report
}

pub fn a_quiet_or_failed_gate_leaves_the_turn_alone_test() {
  use dir <- with_dir
  let seen = process.new_subject()
  let #(messages, report) =
    gate.prepare_with(
      settings(fake("0.02", seen)),
      turn(),
      "bom dia!",
      dir,
      "telegram:42",
      -180,
    )
  messages |> should.equal(turn())
  let assert Some(gate.Report(verdict: gate.Quiet(_), recall: None, ..)) =
    report
  let broken = fn(_, _, _) { Error("econnrefused") }
  let #(messages, _) =
    gate.prepare_with(
      settings(broken),
      turn(),
      "lembra?",
      dir,
      "telegram:42",
      -180,
    )
  messages |> should.equal(turn())
}

/// With the memory off nothing is asked and nothing changes (I5).
pub fn memory_off_changes_nothing_test() {
  runtime.clear()
  gate.prepare(turn(), "lembra do médico?", "/d", "telegram:42", -180)
  |> should.equal(#(turn(), None))
}

/// Counters and histograms, with no text, principal or chat in any label
/// (I7).
pub fn metrics_carry_no_text_test() {
  let report =
    gate.Report(
      verdict: gate.Fired(0.93),
      gate_ms: 300,
      recall: None,
      recall_ms: 0,
    )
  let series = metrics.turn_series(report)
  list.contains(
    series,
    metrics.Count(metrics.gate_total, 1, [
      #("result", "fired"),
      #("reason", "none"),
    ]),
  )
  |> should.be_true()
  let failed =
    metrics.turn_series(gate.Report(
      verdict: gate.Failed(decision.Blocked("Input blocked: palavra")),
      gate_ms: 10,
      recall: None,
      recall_ms: 0,
    ))
  list.contains(
    failed,
    metrics.Count(metrics.gate_total, 1, [
      #("result", "failed"),
      #("reason", "blocked"),
    ]),
  )
  |> should.be_true()
  list.flatten([series, failed])
  |> list.flat_map(fn(s) {
    case s {
      metrics.Count(_, _, labels) -> labels
      metrics.Duration(_, _, labels) -> labels
    }
  })
  |> list.each(fn(label) {
    let #(key, value) = label
    list.contains(["result", "reason", "origin", "band", "failure"], key)
    |> should.be_true()
    string.contains(value, "palavra") |> should.be_false()
  })
}

/// Every call is charged to the person; past the day's cap the gate and
/// lembrar stand aside (6.7).
pub fn calls_are_charged_and_the_cap_stops_the_memory_test() {
  use dir <- with_dir
  let store = HistoryStore(data_dir: dir, limit: 100)
  let assert Ok(Nil) =
    history_store.append(store, "telegram:42:42", [
      StoredMessage(role: "user", content: "é o dr. Otávio Lacerda", at: base),
    ])
  let charges = process.new_subject()
  let seen = process.new_subject()
  let charging =
    runtime.Settings(
      ..settings(fake("0.93", seen)),
      charge: fn(principal, decision_tokens, embed_tokens) {
        process.send(charges, #(principal, decision_tokens, embed_tokens))
      },
    )
  let _ =
    gate.prepare_with(
      charging,
      turn(),
      "lembra do médico?",
      dir,
      "telegram:42",
      -180,
    )
  // The gate, then lembrar (its Decision tokens and its embeddings).
  let assert Ok(#("telegram:42", _, 0)) = process.receive(charges, 1000)
  let assert Ok(#("telegram:42", _, embedded)) = process.receive(charges, 1000)
  { embedded > 0 } |> should.be_true()

  let capped =
    runtime.Settings(..settings(fake("0.93", seen)), within_budget: fn() {
      False
    })
  gate.ask(capped, "lembra do médico?") |> should.equal(gate.OverBudget)
  let #(messages, _) =
    gate.prepare_with(
      capped,
      turn(),
      "lembra do médico?",
      dir,
      "telegram:42",
      -180,
    )
  messages |> should.equal(turn())
}

/// Recording without a metrics actor is a no-op, never a crash.
pub fn recording_without_metrics_is_harmless_test() {
  metrics.record_turn(None)
  metrics.record_turn(
    Some(gate.Report(
      verdict: gate.OverBudget,
      gate_ms: 0,
      recall: None,
      recall_ms: 0,
    )),
  )
}
