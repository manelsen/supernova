//// The /metrics body follows the Prometheus text exposition format, so a
//// scrape is accepted: one TYPE per family, cumulative buckets with +Inf,
//// escaped label values and a final newline.

import gleam/list
import gleam/string
import gleeunit/should
import supernova/metrics/actor as metrics_actor

fn body(record: fn(metrics_actor.Metrics) -> Nil) -> String {
  let assert Ok(metrics) = metrics_actor.start()
  record(metrics)
  metrics_actor.get_metrics(metrics)
}

fn lines(text: String) -> List(String) {
  string.split(text, "\n")
}

pub fn one_type_line_per_family_test() {
  let text =
    body(fn(m) {
      metrics_actor.inc_counter(m, "llm_requests_total", [#("status", "ok")])
      metrics_actor.inc_counter(m, "llm_requests_total", [#("status", "error")])
    })
  lines(text)
  |> list.filter(fn(l) { l == "# TYPE llm_requests_total counter" })
  |> list.length
  |> should.equal(1)
  string.contains(text, "llm_requests_total{status=\"ok\"} 1")
  |> should.be_true()
  string.contains(text, "llm_requests_total{status=\"error\"} 1")
  |> should.be_true()
}

pub fn histogram_has_cumulative_buckets_sum_and_count_test() {
  let text =
    body(fn(m) {
      metrics_actor.observe_histogram(m, "llm_request_duration_seconds", 0.3, [
        #("provider", "mistral"),
      ])
      metrics_actor.observe_histogram(m, "llm_request_duration_seconds", 4.0, [
        #("provider", "mistral"),
      ])
    })
  let has = fn(line) { list.contains(lines(text), line) |> should.be_true() }
  has("# TYPE llm_request_duration_seconds histogram")
  has("llm_request_duration_seconds_bucket{provider=\"mistral\",le=\"0.25\"} 0")
  has("llm_request_duration_seconds_bucket{provider=\"mistral\",le=\"0.5\"} 1")
  has("llm_request_duration_seconds_bucket{provider=\"mistral\",le=\"5.0\"} 2")
  has("llm_request_duration_seconds_bucket{provider=\"mistral\",le=\"+Inf\"} 2")
  has("llm_request_duration_seconds_sum{provider=\"mistral\"} 4.3")
  has("llm_request_duration_seconds_count{provider=\"mistral\"} 2")
}

pub fn first_observation_lands_in_its_buckets_test() {
  let text =
    body(fn(m) {
      metrics_actor.observe_histogram(
        m,
        "tool_execution_duration_seconds",
        0.02,
        [],
      )
    })
  list.contains(
    lines(text),
    "tool_execution_duration_seconds_bucket{le=\"0.025\"} 1",
  )
  |> should.be_true()
}

pub fn label_values_are_escaped_test() {
  let text =
    body(fn(m) {
      metrics_actor.inc_counter(m, "x_total", [#("model", "a\"b\\c\nd")])
    })
  string.contains(text, "x_total{model=\"a\\\"b\\\\c\\nd\"} 1")
  |> should.be_true()
}

pub fn gauge_goes_up_and_down_test() {
  let text =
    body(fn(m) {
      metrics_actor.add_gauge(m, "agents_active", 1, [])
      metrics_actor.add_gauge(m, "agents_active", 1, [])
      metrics_actor.add_gauge(m, "agents_active", -1, [])
    })
  list.contains(lines(text), "agents_active 1") |> should.be_true()
  list.contains(lines(text), "# TYPE agents_active gauge") |> should.be_true()
}

pub fn body_ends_with_a_newline_test() {
  let text = body(fn(m) { metrics_actor.inc_counter(m, "x_total", []) })
  string.ends_with(text, "\n") |> should.be_true()
}

pub fn empty_registry_is_an_empty_body_test() {
  body(fn(_) { Nil }) |> should.equal("")
}
