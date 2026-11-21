import exception
import gleam/list
import gleam/string
import gleeunit/should
import supernova/adapters/channel_common_router as router
import supernova/core/executor
import supernova/core/introspection/self_state
import supernova/llm/provider
import supernova/self/incidents
import test_workspace

// 2026-11-21 12:00 in São Paulo.
const now = 1_795_273_200_000

const hour = 3_600_000

const day = 86_400_000

const owner = "telegram:924255495"

fn with_data_dir(body: fn(String) -> a) -> a {
  let dir = test_workspace.create_temp_dir("incidents")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  body(dir)
}

pub fn recent_keeps_order_and_limit_test() {
  use dir <- with_data_dir
  list.each([1, 2, 3, 4, 5, 6, 7], fn(n) {
    let assert Ok(_) =
      incidents.record(
        dir,
        owner,
        now + n * hour,
        "falha " <> string.inspect(n),
      )
    Nil
  })
  incidents.recent(dir, owner, now + 8 * hour, 5)
  |> list.map(fn(i) { i.text })
  |> should.equal(["falha 3", "falha 4", "falha 5", "falha 6", "falha 7"])
}

pub fn old_incidents_fade_after_a_week_test() {
  use dir <- with_data_dir
  let assert Ok(_) = incidents.record(dir, owner, now, "antiga")
  let assert Ok(_) = incidents.record(dir, owner, now + 6 * day, "recente")
  incidents.recent(dir, owner, now + 7 * day + hour, 5)
  |> list.map(fn(i) { i.text })
  |> should.equal(["recente"])
}

pub fn incidents_are_per_person_test() {
  use dir <- with_data_dir
  let assert Ok(_) = incidents.record(dir, owner, now, "minha")
  incidents.recent(dir, "telegram:1", now, 5) |> should.equal([])
}

pub fn file_keeps_a_bounded_history_test() {
  use dir <- with_data_dir
  list.repeat(Nil, incidents.max_kept + 10)
  |> list.each(fn(_) {
    let assert Ok(_) = incidents.record(dir, owner, now, "x")
    Nil
  })
  incidents.count(dir, owner) |> should.equal(incidents.max_kept)
}

pub fn clear_removes_everything_test() {
  use dir <- with_data_dir
  let assert Ok(_) = incidents.record(dir, owner, now, "a")
  let assert Ok(_) = incidents.record(dir, owner, now, "b")
  incidents.clear(dir, owner) |> should.equal(Ok(2))
  incidents.recent(dir, owner, now, 5) |> should.equal([])
}

pub fn prompt_block_test() {
  incidents.prompt_block([], -180) |> should.equal("")
  incidents.prompt_block(
    [incidents.Incident(at: now, text: "a ferramenta safe_shell recusou")],
    -180,
  )
  |> should.equal(
    "O que aconteceu por aqui:\n- 21/11/2026 12:00: a ferramenta safe_shell recusou",
  )
}

pub fn text_stays_on_one_line_and_short_test() {
  use dir <- with_data_dir
  let long = string.repeat("a", 500)
  let assert Ok(_) =
    incidents.record(dir, owner, now, "linha\nforjada " <> long)
  let assert [incident] = incidents.recent(dir, owner, now, 5)
  string.contains(incident.text, "\n") |> should.be_false
  { string.length(incident.text) <= incidents.max_text_length }
  |> should.be_true
}

// The mood cause reads as something a person would say; technical causes
// point at the incidents instead of naming internals.
pub fn mood_cause_is_human_test() {
  let state = self_state.default()
  let failed = self_state.SelfState(..state, mood_cause: "llm_error")
  let block = self_state.prompt_block(failed)
  string.contains(block, "llm_error") |> should.be_false
  string.contains(block, "O que aconteceu por aqui") |> should.be_true
  let fine = self_state.SelfState(..state, mood_cause: "turn_success")
  string.contains(self_state.prompt_block(fine), "turn_success")
  |> should.be_false
}

// A provider's error body can echo conversation text; the incident keeps
// only the status and the error type.
pub fn provider_refusal_keeps_no_conversation_text_test() {
  let text =
    router.incident_text(
      executor.LLMError(provider.NetworkError(
        "API error 422: {\"detail\":[{\"type\":\"extra_forbidden\",\"loc\":[\"body\",\"messages\",3],\"msg\":\"SEGREDO\",\"input\":\"SEGREDO\"}]}",
      )),
    )
  string.contains(text, "SEGREDO") |> should.be_false
  string.contains(text, "422") |> should.be_true
  string.contains(text, "extra_forbidden") |> should.be_true
  router.incident_text(
    executor.LLMError(provider.NetworkError(
      "Network error connecting to https://api.mistral.ai/v1/chat/completions",
    )),
  )
  |> should.equal("não consegui falar com o provedor do modelo (falha de rede)")
}

pub fn recent_is_ordered_by_time_test() {
  use dir <- with_data_dir
  let assert Ok(_) = incidents.record(dir, owner, now + 2 * hour, "depois")
  let assert Ok(_) = incidents.record(dir, owner, now + hour, "antes")
  incidents.recent(dir, owner, now + 3 * hour, 5)
  |> list.map(fn(i) { i.text })
  |> should.equal(["antes", "depois"])
}

pub fn unreadable_history_is_not_replaced_test() {
  use dir <- with_data_dir
  let assert Ok(_) = incidents.record(dir, owner, now, "a")
  let file = incidents.path(dir, owner)
  // As root the file stays readable; there is nothing to check then.
  case make_unreadable(file) {
    Error(Nil) -> Nil
    Ok(Nil) -> {
      incidents.record(dir, owner, now, "b") |> should.be_error
      let assert Ok(_) = make_readable(file)
      incidents.count(dir, owner) |> should.equal(1)
    }
  }
}

// A producer racing /esquecer: the guard runs inside the lock, after the
// forget bumped its epoch, so nothing is written back.
pub fn guarded_record_skips_when_stale_test() {
  use dir <- with_data_dir
  incidents.record_if(dir, owner, now, "tarde demais", fn() { False })
  |> should.equal(Ok(Nil))
  incidents.count(dir, owner) |> should.equal(0)
  let assert Ok(_) =
    incidents.record_if(dir, owner, now, "a tempo", fn() { True })
  incidents.count(dir, owner) |> should.equal(1)
}

@external(erlang, "incidents_test_ffi", "make_unreadable")
fn make_unreadable(path: String) -> Result(Nil, Nil)

@external(erlang, "incidents_test_ffi", "make_readable")
fn make_readable(path: String) -> Result(Nil, Nil)

pub fn newest_survives_equal_timestamps_test() {
  use dir <- with_data_dir
  list.repeat(Nil, incidents.max_kept)
  |> list.each(fn(_) {
    let assert Ok(_) = incidents.record(dir, owner, now, "antiga")
    Nil
  })
  let assert Ok(_) = incidents.record(dir, owner, now, "nova")
  incidents.count(dir, owner) |> should.equal(incidents.max_kept)
  let assert Ok(last) =
    incidents.recent(dir, owner, now, 1)
    |> list.map(fn(i) { i.text })
    |> list.first
  last |> should.equal("nova")
}
