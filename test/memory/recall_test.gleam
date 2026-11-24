//// lembrar (PRD-M, 6.4): excerpts in compact form, a short list by vector
//// and by words, the tone from the general probability, the excerpts word
//// for word, the index kept next to the conversations and gone with
//// /esquecer, only the caller's conversations, and every failure turned
//// into a pointer to buscar_conversa.

import exception
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/core/session/history_store.{HistoryStore, StoredMessage}
import supernova/memory/decision
import supernova/memory/recall
import supernova/memory/runtime
import supernova/tools/buscar_conversa
import test_workspace

// 2026-11-26 12:00 UTC, in milliseconds.
const base = 1_795_694_400_000

const minute = 60_000

const day = 86_400_000

fn with_dir(body: fn(String) -> a) -> a {
  let dir = test_workspace.create_temp_dir("recall")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  body(dir)
}

fn say(dir: String, session: String, messages: List(#(String, String, Int))) {
  let store = HistoryStore(data_dir: dir, limit: 100)
  let stored =
    list.map(messages, fn(m) {
      StoredMessage(role: m.0, content: m.1, at: base + m.2 * minute)
    })
  let assert Ok(Nil) = history_store.append(store, session, stored)
  Nil
}

/// Twelve filler exchanges, then the heart doctor, in another chat.
fn seed(dir: String) {
  say(
    dir,
    "telegram:42:42",
    int.range(0, 24, [], list.prepend)
      |> list.reverse
      |> list.map(fn(i) {
        case i % 2 {
          0 -> #("user", "fiz bolo de fubá hoje", i)
          _ -> #("assistant", "Que delícia!", i)
        }
      }),
  )
  say(dir, "telegram:-100:42", [
    #("user", "levei minha mãe no cardiologista", 30),
    #("assistant", "Como foi?", 31),
    #("user", "é o dr. Otávio Lacerda", 32),
  ])
}

/// Vectors by topic; the Decision says excerpt 3 (the doctor) is it.
fn fake(general: Float, calls: process.Subject(String)) -> decision.Transport {
  fn(url, _headers, body) {
    case url == decision.embed_url {
      True -> {
        let kind = case string.contains(body, "RETRIEVAL_QUERY") {
          True -> "query"
          False -> "document"
        }
        process.send(calls, kind)
        let v = case string.contains(body, "cardiolog") {
          True -> "[1,0]"
          False -> "[0,1]"
        }
        Ok(#(200, "{\"embedding\":{\"values\":" <> v <> "}}"))
      }
      False -> {
        process.send(calls, "decide")
        Ok(#(
          200,
          "{\"answers\":{\"falado\":{\"noul\":"
            <> float_json(general)
            <> "},\"t3\":{\"noul\":0.9},\"t1\":{\"noul\":0.05}},\"usage\":{\"total_input_tokens\":700}}",
        ))
      }
    }
  }
}

fn float_json(f: Float) -> String {
  let cents = { f *. 100.0 } |> float_round
  "0." <> string.pad_start(int.to_string(cents), 2, "0")
}

@external(erlang, "erlang", "round")
fn float_round(f: Float) -> Int

fn settings(transport: decision.Transport) -> runtime.Settings {
  runtime.Settings(
    transport: transport,
    api_key: "k",
    gate_threshold: 0.1,
    gate_timeout_ms: 2000,
    recall_timeout_ms: 5000,
    charge: runtime.no_charge,
    within_budget: runtime.always_within,
  )
}

fn drain(calls: process.Subject(String), acc: List(String)) -> List(String) {
  case process.receive(calls, 0) {
    Ok(kind) -> drain(calls, [kind, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

pub fn compact_text_says_the_date_once_and_who_spoke_test() {
  let excerpt =
    recall.Excerpt(index: 4, messages: [
      StoredMessage(role: "user", content: "oi\ntudo bem?", at: base),
      StoredMessage(role: "assistant", content: "Tudo!", at: base + minute),
      StoredMessage(role: "user", content: "e amanhã?", at: base + day),
    ])
  recall.compact_text(excerpt, -180)
  |> should.equal(
    "### Trecho 5, 26/11/2026\nP: oi tudo bem?\nA: Tudo!\n(27/11/2026)\nP: e amanhã?",
  )
  recall.full_text(excerpt, -180)
  |> string.starts_with(
    "### Trecho 5\n[26/11/2026 09:00] pessoa: oi tudo bem?\n[26/11/2026 09:01] você: Tudo!",
  )
  |> should.be_true()
}

pub fn words_fold_cut_and_skip_the_commonest_test() {
  recall.words("Qual o nome do CARDIOLOGISTA da minha mãe?")
  |> should.equal(["nome", "cardi"])
  recall.words("consultas e consulta") |> should.equal(["consu", "consu"])
}

pub fn shortlist_takes_the_nearest_and_the_shared_words_test() {
  let compact = ["fubá bolo", "nada", "cardiologista", "reunião", "nada"]
  let similarity = fn(i) {
    case i {
      // The vector likes the meeting best; excerpt 1 has no vector yet.
      3 -> Some(0.9)
      2 -> Some(0.5)
      1 -> None
      _ -> Some(0.1)
    }
  }
  let list = recall.shortlist("o cardiologista", compact, similarity)
  // Every excerpt with a vector (fewer than 30) plus the one sharing a word,
  // in order of time; the one without a vector only by words.
  list |> should.equal([0, 2, 3, 4])
}

pub fn tone_follows_the_general_probability_test() {
  recall.tone(0.08)
  |> string.contains("Diga que acha que não, sem afirmar com certeza")
  |> should.be_true()
  recall.tone(0.5)
  |> string.contains("diga que não se lembra bem e pergunte")
  |> should.be_true()
  recall.tone(0.93)
  |> should.equal(
    "Provável que vocês já tenham falado disso (probabilidade 0.93).",
  )
}

pub fn recall_shows_the_excerpt_word_for_word_test() {
  use dir <- with_dir
  seed(dir)
  let calls = process.new_subject()
  let outcome =
    recall.recall(
      settings(fake(0.93, calls)),
      dir,
      "telegram:42",
      -180,
      "nome do cardiologista",
    )
  outcome.probability |> should.equal(Some(0.93))
  outcome.failure |> should.equal(None)
  outcome.decision_tokens |> should.equal(700)
  let text = outcome.text
  text
  |> string.starts_with(
    "Provável que vocês já tenham falado disso (probabilidade 0.93).",
  )
  |> should.be_true()
  text |> string.contains("pessoa: é o dr. Otávio Lacerda") |> should.be_true()
  // Only the excerpt the Decision pointed to (3); the one it gave 0.05 (1)
  // and the one it did not mention (2) are not shown.
  text |> string.contains("### Trecho 3\n") |> should.be_true()
  text |> string.contains("### Trecho 1\n") |> should.be_false()
  text |> string.contains("### Trecho 2\n") |> should.be_false()
  text |> string.ends_with(buscar_conversa.found_hint) |> should.be_true()
  // 27 messages: three excerpts, each embedded once, plus the query.
  let kinds = drain(calls, [])
  list.count(kinds, fn(k) { k == "document" }) |> should.equal(3)
  list.count(kinds, fn(k) { k == "query" }) |> should.equal(1)

  // The second call reads the index: only the query is embedded.
  let _ =
    recall.recall(
      settings(fake(0.93, calls)),
      dir,
      "telegram:42",
      -180,
      "o médico",
    )
  drain(calls, [])
  |> list.count(fn(k) { k == "document" })
  |> should.equal(0)
}

pub fn recall_says_unlikely_with_doubt_test() {
  use dir <- with_dir
  seed(dir)
  let calls = process.new_subject()
  let outcome =
    recall.recall(
      settings(fake(0.05, calls)),
      dir,
      "telegram:42",
      -180,
      "viagem pra Lisboa",
    )
  outcome.text
  |> string.starts_with(
    "Pouco provável que vocês tenham falado disso (probabilidade 0.05).",
  )
  |> should.be_true()
}

/// Another person's words are never read (I3).
pub fn recall_reads_only_the_callers_conversations_test() {
  use dir <- with_dir
  seed(dir)
  say(dir, "telegram:7:7", [#("user", "segredo da outra pessoa", 1)])
  let calls = process.new_subject()
  let outcome =
    recall.recall(
      settings(fake(0.93, calls)),
      dir,
      "telegram:42",
      -180,
      "segredo",
    )
  outcome.text |> string.contains("segredo") |> should.be_false()
  let assert Ok(said) = recall.said(dir, "telegram:42")
  list.length(said) |> should.equal(27)
}

pub fn recall_with_nothing_said_test() {
  use dir <- with_dir
  let calls = process.new_subject()
  recall.recall(settings(fake(0.9, calls)), dir, "telegram:42", -180, "algo").text
  |> should.equal(
    "Vocês ainda não têm conversas guardadas além das mensagens que você vê.",
  )
  drain(calls, []) |> should.equal([])
}

/// The safety filter, a timeout and an error all become a pointer to
/// buscar_conversa, never an error for the person (I6).
pub fn recall_failures_point_to_buscar_conversa_test() {
  use dir <- with_dir
  seed(dir)
  let blocked = fn(url, _headers, _body) {
    case url == decision.embed_url {
      True -> Ok(#(200, "{\"embedding\":{\"values\":[1,0]}}"))
      False ->
        Ok(#(
          400,
          "{\"error\":{\"message\":\"Input blocked: sensitive words\"}}",
        ))
    }
  }
  let outcome = recall.recall(settings(blocked), dir, "telegram:42", -180, "x")
  let assert Some(decision.Blocked(_)) = outcome.failure
  outcome.text |> string.contains("filtro de segurança") |> should.be_true()
  outcome.text |> string.contains("buscar_conversa") |> should.be_true()

  let never = fn(_url, _headers, _body) {
    let nothing = process.new_subject()
    let _ = process.receive(nothing, 60_000)
    Ok(#(200, "{}"))
  }
  let slow =
    recall.recall(
      runtime.Settings(..settings(never), recall_timeout_ms: 50),
      dir,
      "telegram:42",
      -180,
      "x",
    )
  slow.failure |> should.equal(Some(decision.TimedOut))
  slow.text |> string.contains("buscar_conversa") |> should.be_true()
}

/// The index lives with the conversations: /esquecer clears that directory,
/// index and all (I4).
pub fn the_index_lives_with_the_conversations_test() {
  recall.index_path("/d", "telegram:42")
  |> should.equal(history_store.dir("/d", "telegram:42") <> "/recall.idx")
  // Not a conversation file: buscar_conversa only reads *.jsonl.
  recall.index_path("/d", "telegram:42")
  |> string.ends_with(".jsonl")
  |> should.be_false()
}

pub fn recall_stands_aside_past_the_cap_test() {
  use dir <- with_dir
  seed(dir)
  let calls = process.new_subject()
  let capped =
    runtime.Settings(..settings(fake(0.9, calls)), within_budget: fn() { False })
  let outcome = recall.recall(capped, dir, "telegram:42", -180, "o médico")
  outcome.text |> string.contains("limite de gasto do dia") |> should.be_true()
  outcome.text |> string.contains("buscar_conversa") |> should.be_true()
  drain(calls, []) |> should.equal([])
}
