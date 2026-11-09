import gleam/string
import gleeunit
import gleeunit/should
import supernova/metrics/types as metrics

pub fn main() {
  gleeunit.main()
}

pub fn format_metrics_renders_counter_gauge_histogram_test() {
  let rendered =
    metrics.format_metrics(
      [
        metrics.CounterMetric(
          name: "supernova_requests_total",
          value: 7,
          labels: [#("channel", "discord")],
        ),
      ],
      [
        metrics.GaugeMetric(
          name: "supernova_active_sessions",
          value: 3,
          labels: [],
        ),
      ],
      [
        metrics.HistogramMetric(
          name: "supernova_latency_seconds",
          count: 2,
          sum: 1.5,
          buckets: [#(0.5, 1), #(1.0, 2)],
          labels: [#("route", "/health")],
        ),
      ],
    )

  string.contains(rendered, "# TYPE supernova_requests_total counter")
  |> should.equal(True)
  string.contains(rendered, "supernova_requests_total{channel=\"discord\"} 7")
  |> should.equal(True)
  string.contains(rendered, "# TYPE supernova_active_sessions gauge")
  |> should.equal(True)
  string.contains(rendered, "supernova_active_sessions 3")
  |> should.equal(True)
  string.contains(rendered, "# TYPE supernova_latency_seconds histogram")
  |> should.equal(True)
  string.contains(rendered, "supernova_latency_seconds_count{route=\"/health\"} 2")
  |> should.equal(True)
  string.contains(rendered, "supernova_latency_seconds_sum{route=\"/health\"} 1.5")
  |> should.equal(True)
}
