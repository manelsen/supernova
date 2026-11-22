//// Prometheus metrics actor.
////
//// Collects and exposes metrics in Prometheus text format.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor

import supernova/metrics/types as metrics_types

pub type Metrics =
  Subject(MetricsCommand)

pub type MetricsCommand {
  IncCounter(name: String, labels: List(#(String, String)))
  AddCounter(name: String, amount: Int, labels: List(#(String, String)))
  SetGauge(name: String, value: Int, labels: List(#(String, String)))
  AddGauge(name: String, delta: Int, labels: List(#(String, String)))
  ObserveHistogram(name: String, value: Float, labels: List(#(String, String)))
  GetMetrics(reply_to: Subject(String))
  Reset(reply_to: Subject(Nil))
}

fn handle_message(
  state: metrics_types.MetricsRegistry,
  message: MetricsCommand,
) -> actor.Next(metrics_types.MetricsRegistry, MetricsCommand) {
  case message {
    IncCounter(name, labels) ->
      handle_message(state, AddCounter(name, 1, labels))
    AddCounter(name, amount, labels) -> {
      let new_counters = case find_counter(state.counters, name, labels) {
        Ok(c) -> update_counter(state.counters, name, labels, c.value + amount)
        Error(Nil) ->
          list.prepend(
            state.counters,
            metrics_types.CounterMetric(
              name: name,
              value: amount,
              labels: labels,
            ),
          )
      }
      actor.continue(metrics_types.MetricsRegistry(
        counters: new_counters,
        gauges: state.gauges,
        histograms: state.histograms,
      ))
    }
    SetGauge(name, value, labels) -> {
      let new_gauges = case find_gauge(state.gauges, name, labels) {
        Ok(_) -> update_gauge(state.gauges, name, labels, value)
        Error(Nil) ->
          list.prepend(
            state.gauges,
            metrics_types.GaugeMetric(name: name, value: value, labels: labels),
          )
      }
      actor.continue(metrics_types.MetricsRegistry(
        counters: state.counters,
        gauges: new_gauges,
        histograms: state.histograms,
      ))
    }
    AddGauge(name, delta, labels) -> {
      let new_gauges = case find_gauge(state.gauges, name, labels) {
        Ok(g) -> update_gauge(state.gauges, name, labels, g.value + delta)
        Error(Nil) ->
          list.prepend(
            state.gauges,
            metrics_types.GaugeMetric(name: name, value: delta, labels: labels),
          )
      }
      actor.continue(metrics_types.MetricsRegistry(..state, gauges: new_gauges))
    }
    ObserveHistogram(name, value, labels) -> {
      let new_histograms = case find_histogram(state.histograms, name, labels) {
        Ok(h) ->
          update_histogram(
            state.histograms,
            name,
            labels,
            h.count + 1,
            h.sum +. value,
            metrics_types.observe_buckets(h.buckets, value),
          )
        Error(Nil) ->
          list.prepend(
            state.histograms,
            metrics_types.HistogramMetric(
              name: name,
              count: 1,
              sum: value,
              buckets: metrics_types.buckets_for(name)
                |> list.map(fn(upper) { #(upper, 0) })
                |> metrics_types.observe_buckets(value),
              labels: labels,
            ),
          )
      }
      actor.continue(metrics_types.MetricsRegistry(
        counters: state.counters,
        gauges: state.gauges,
        histograms: new_histograms,
      ))
    }
    GetMetrics(reply_to) -> {
      let output =
        metrics_types.format_metrics(
          state.counters,
          state.gauges,
          state.histograms,
        )
      actor.send(reply_to, output)
      actor.continue(state)
    }
    Reset(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.continue(
        metrics_types.MetricsRegistry(counters: [], gauges: [], histograms: []),
      )
    }
  }
}

fn find_counter(
  counters: List(metrics_types.CounterMetric),
  name: String,
  labels: List(#(String, String)),
) -> Result(metrics_types.CounterMetric, Nil) {
  case counters {
    [] -> Error(Nil)
    [c, ..rest] -> {
      case c.name == name && c.labels == labels {
        True -> Ok(c)
        False -> find_counter(rest, name, labels)
      }
    }
  }
}

fn update_counter(
  counters: List(metrics_types.CounterMetric),
  name: String,
  labels: List(#(String, String)),
  new_value: Int,
) -> List(metrics_types.CounterMetric) {
  list.map(counters, fn(c) {
    case c.name == name && c.labels == labels {
      True ->
        metrics_types.CounterMetric(
          name: c.name,
          value: new_value,
          labels: c.labels,
        )
      False -> c
    }
  })
}

fn find_gauge(
  gauges: List(metrics_types.GaugeMetric),
  name: String,
  labels: List(#(String, String)),
) -> Result(metrics_types.GaugeMetric, Nil) {
  case gauges {
    [] -> Error(Nil)
    [g, ..rest] -> {
      case g.name == name && g.labels == labels {
        True -> Ok(g)
        False -> find_gauge(rest, name, labels)
      }
    }
  }
}

fn update_gauge(
  gauges: List(metrics_types.GaugeMetric),
  name: String,
  labels: List(#(String, String)),
  new_value: Int,
) -> List(metrics_types.GaugeMetric) {
  list.map(gauges, fn(g) {
    case g.name == name && g.labels == labels {
      True ->
        metrics_types.GaugeMetric(
          name: g.name,
          value: new_value,
          labels: g.labels,
        )
      False -> g
    }
  })
}

fn find_histogram(
  histograms: List(metrics_types.HistogramMetric),
  name: String,
  labels: List(#(String, String)),
) -> Result(metrics_types.HistogramMetric, Nil) {
  case histograms {
    [] -> Error(Nil)
    [h, ..rest] -> {
      case h.name == name && h.labels == labels {
        True -> Ok(h)
        False -> find_histogram(rest, name, labels)
      }
    }
  }
}

fn update_histogram(
  histograms: List(metrics_types.HistogramMetric),
  name: String,
  labels: List(#(String, String)),
  new_count: Int,
  new_sum: Float,
  new_buckets: List(#(Float, Int)),
) -> List(metrics_types.HistogramMetric) {
  list.map(histograms, fn(h) {
    case h.name == name && h.labels == labels {
      True ->
        metrics_types.HistogramMetric(
          name: h.name,
          count: new_count,
          sum: new_sum,
          buckets: new_buckets,
          labels: h.labels,
        )
      False -> h
    }
  })
}

pub fn start() -> Result(Metrics, actor.StartError) {
  case start_linked() {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Start and return the full Started record (for use with supervisors).
pub fn start_linked() -> Result(actor.Started(Metrics), actor.StartError) {
  let initial =
    metrics_types.MetricsRegistry(counters: [], gauges: [], histograms: [])
  actor.new(initial)
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn inc_counter(
  metrics: Metrics,
  name: String,
  labels: List(#(String, String)),
) {
  actor.send(metrics, IncCounter(name, labels))
}

/// Add a non-negative amount to a counter (tokens, cost in micro-USD).
pub fn add_counter(
  metrics: Metrics,
  name: String,
  amount: Int,
  labels: List(#(String, String)),
) {
  actor.send(metrics, AddCounter(name, int.max(amount, 0), labels))
}

pub fn set_gauge(
  metrics: Metrics,
  name: String,
  value: Int,
  labels: List(#(String, String)),
) {
  actor.send(metrics, SetGauge(name, value, labels))
}

/// Move a gauge up or down by `delta`.
pub fn add_gauge(
  metrics: Metrics,
  name: String,
  delta: Int,
  labels: List(#(String, String)),
) {
  actor.send(metrics, AddGauge(name, delta, labels))
}

pub fn observe_histogram(
  metrics: Metrics,
  name: String,
  value: Float,
  labels: List(#(String, String)),
) {
  actor.send(metrics, ObserveHistogram(name, value, labels))
}

pub fn get_metrics(metrics: Metrics) -> String {
  actor.call(metrics, waiting: 5000, sending: GetMetrics)
}

pub fn reset(metrics: Metrics) {
  actor.call(metrics, waiting: 5000, sending: Reset)
}
