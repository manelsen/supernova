//// Prometheus metrics types and utilities.
////
//// Provides counter, gauge, histogram, and registry for metrics.

import gleam/float
import gleam/int
import gleam/list
import gleam/string

pub type Metric {
  Counter(name: String, value: Int, labels: List(#(String, String)))
  Gauge(name: String, value: Int, labels: List(#(String, String)))
  Histogram(name: String, value: Float, labels: List(#(String, String)))
}

pub type MetricsRegistry {
  MetricsRegistry(
    counters: List(CounterMetric),
    gauges: List(GaugeMetric),
    histograms: List(HistogramMetric),
  )
}

pub type CounterMetric {
  CounterMetric(name: String, value: Int, labels: List(#(String, String)))
}

pub type GaugeMetric {
  GaugeMetric(name: String, value: Int, labels: List(#(String, String)))
}

pub type HistogramMetric {
  HistogramMetric(
    name: String,
    count: Int,
    sum: Float,
    buckets: List(#(Float, Int)),
    labels: List(#(String, String)),
  )
}

pub fn format_metrics(
  counters: List(CounterMetric),
  gauges: List(GaugeMetric),
  histograms: List(HistogramMetric),
) -> String {
  let lines = []
  let lines = list.append(lines, format_counters(counters))
  let lines = list.append(lines, format_gauges(gauges))
  let lines = list.append(lines, format_histograms(histograms))
  string.join(lines, "\n")
}

fn format_counters(counters: List(CounterMetric)) -> List(String) {
  list.map(counters, fn(c) {
    let labels = format_labels(c.labels)
    "# TYPE "
    <> c.name
    <> " counter\n"
    <> c.name
    <> labels
    <> " "
    <> int.to_string(c.value)
  })
}

fn format_gauges(gauges: List(GaugeMetric)) -> List(String) {
  list.map(gauges, fn(g) {
    let labels = format_labels(g.labels)
    "# TYPE "
    <> g.name
    <> " gauge\n"
    <> g.name
    <> labels
    <> " "
    <> int.to_string(g.value)
  })
}

fn format_histograms(histograms: List(HistogramMetric)) -> List(String) {
  list.fold(histograms, [], fn(acc, h) {
    let labels = format_labels(h.labels)
    let lines = [
      "# TYPE " <> h.name <> " histogram",
      h.name <> "_count" <> labels <> " " <> int.to_string(h.count),
      h.name <> "_sum" <> labels <> " " <> float_to_string(h.sum),
      ..acc
    ]
    list.fold(h.buckets, lines, fn(bacc, bucket) {
      let #(_upper, _count) = bucket
      bacc
    })
  })
}

fn format_labels(labels: List(#(String, String))) -> String {
  case labels {
    [] -> ""
    _ -> {
      let pairs = list.map(labels, fn(l) { l.0 <> "=\"" <> l.1 <> "\"" })
      "{" <> string.join(pairs, ",") <> "}"
    }
  }
}

fn float_to_string(f: Float) -> String {
  float.to_string(f)
}
