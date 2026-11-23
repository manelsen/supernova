//// One-line recording for instrumented code. Every call is a no-op when no
//// metrics actor is registered (tests that do not start one, early boot).

import gleam/int
import gleam/option
import supernova/metrics/actor as metrics_actor
import supernova/metrics/global as metrics_global

pub fn count(name: String, labels: List(#(String, String))) -> Nil {
  with_metrics(fn(metrics) { metrics_actor.inc_counter(metrics, name, labels) })
}

pub fn count_by(
  name: String,
  amount: Int,
  labels: List(#(String, String)),
) -> Nil {
  with_metrics(fn(metrics) {
    metrics_actor.add_counter(metrics, name, amount, labels)
  })
}

/// Observe a duration given in milliseconds, in a `_seconds` histogram.
pub fn duration_ms(
  name: String,
  elapsed_ms: Int,
  labels: List(#(String, String)),
) -> Nil {
  with_metrics(fn(metrics) {
    metrics_actor.observe_histogram(
      metrics,
      name,
      int.to_float(elapsed_ms) /. 1000.0,
      labels,
    )
  })
}

/// Publish a counter series at zero before its first event. Prometheus's
/// `increase` only counts what comes after a series' first sample, so a
/// series born at 1 loses that first event; declared at boot, it does not.
pub fn declare(name: String, labels: List(#(String, String))) -> Nil {
  count_by(name, 0, labels)
}

/// Publish a `_seconds` histogram series with no observations yet.
pub fn declare_duration(name: String, labels: List(#(String, String))) -> Nil {
  with_metrics(fn(metrics) {
    metrics_actor.declare_histogram(metrics, name, labels)
  })
}

fn with_metrics(record: fn(metrics_actor.Metrics) -> Nil) -> Nil {
  case metrics_global.get_metrics() {
    option.Some(metrics) -> record(metrics)
    option.None -> Nil
  }
}
