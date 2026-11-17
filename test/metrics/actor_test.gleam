import gleam/string
import gleeunit
import gleeunit/should
import supernova/metrics/actor as metrics_actor

pub fn main() {
  gleeunit.main()
}

pub fn counters_gauges_histograms_and_reset_test() {
  let assert Ok(metrics) = metrics_actor.start()

  metrics_actor.inc_counter(metrics, "requests_total", [#("channel", "discord")])
  metrics_actor.inc_counter(metrics, "requests_total", [#("channel", "discord")])
  metrics_actor.set_gauge(metrics, "active_sessions", 10, [])
  metrics_actor.set_gauge(metrics, "active_sessions", 12, [])
  metrics_actor.observe_histogram(metrics, "request_latency", 0.5, [])
  metrics_actor.observe_histogram(metrics, "request_latency", 1.0, [])

  let rendered = metrics_actor.get_metrics(metrics)
  rendered
  |> string.contains("requests_total{channel=\"discord\"} 2")
  |> should.equal(True)
  rendered |> string.contains("active_sessions 12") |> should.equal(True)
  rendered |> string.contains("request_latency_count 2") |> should.equal(True)
  rendered |> string.contains("request_latency_sum 1.5") |> should.equal(True)

  metrics_actor.reset(metrics)

  let after_reset = metrics_actor.get_metrics(metrics)
  after_reset |> should.equal("")
}
