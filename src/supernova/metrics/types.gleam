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

/// Bucket upper bounds for a histogram, by its name: durations in seconds
/// (LLM calls can take minutes), scores and ratios between 0 and 1.
pub fn buckets_for(name: String) -> List(Float) {
  case string.ends_with(name, "_score") || string.ends_with(name, "_ratio") {
    True -> [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    False -> [
      0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0,
      120.0,
    ]
  }
}

/// Count one observation in cumulative buckets: every bucket whose upper
/// bound is at least `value`.
pub fn observe_buckets(
  buckets: List(#(Float, Int)),
  value: Float,
) -> List(#(Float, Int)) {
  list.map(buckets, fn(bucket) {
    case value <=. bucket.0 {
      True -> #(bucket.0, bucket.1 + 1)
      False -> bucket
    }
  })
}

/// Render the registry in the Prometheus text exposition format: one TYPE
/// line per family, then its series; histograms as cumulative `_bucket`
/// series ending in `le="+Inf"`, then `_sum` and `_count`. The body ends with
/// a newline, or is empty when nothing was recorded.
pub fn format_metrics(
  counters: List(CounterMetric),
  gauges: List(GaugeMetric),
  histograms: List(HistogramMetric),
) -> String {
  let counter_lines =
    families(counters, fn(c: CounterMetric) { c.name })
    |> list.flat_map(fn(family) {
      let #(name, series) = family
      [
        "# TYPE " <> name <> " counter",
        ..list.map(series, fn(c: CounterMetric) {
          name <> format_labels(c.labels) <> " " <> int.to_string(c.value)
        })
      ]
    })
  let gauge_lines =
    families(gauges, fn(g: GaugeMetric) { g.name })
    |> list.flat_map(fn(family) {
      let #(name, series) = family
      [
        "# TYPE " <> name <> " gauge",
        ..list.map(series, fn(g: GaugeMetric) {
          name <> format_labels(g.labels) <> " " <> int.to_string(g.value)
        })
      ]
    })
  let histogram_lines =
    families(histograms, fn(h: HistogramMetric) { h.name })
    |> list.flat_map(fn(family) {
      let #(name, series) = family
      [
        "# TYPE " <> name <> " histogram",
        ..list.flat_map(series, histogram_series)
      ]
    })
  case list.flatten([counter_lines, gauge_lines, histogram_lines]) {
    [] -> ""
    lines -> string.join(lines, "\n") <> "\n"
  }
}

fn histogram_series(h: HistogramMetric) -> List(String) {
  let bucket_lines =
    list.map(h.buckets, fn(bucket) {
      h.name
      <> "_bucket"
      <> format_labels(
        list.append(h.labels, [#("le", float.to_string(bucket.0))]),
      )
      <> " "
      <> int.to_string(bucket.1)
    })
  list.flatten([
    bucket_lines,
    [
      h.name
        <> "_bucket"
        <> format_labels(list.append(h.labels, [#("le", "+Inf")]))
        <> " "
        <> int.to_string(h.count),
      h.name
        <> "_sum"
        <> format_labels(h.labels)
        <> " "
        <> float_to_string(h.sum),
      h.name
        <> "_count"
        <> format_labels(h.labels)
        <> " "
        <> int.to_string(h.count),
    ],
  ])
}

/// Group series by family name; families sorted by name, series in the
/// order they were first recorded.
fn families(
  items: List(a),
  name_of: fn(a) -> String,
) -> List(#(String, List(a))) {
  let ordered = list.reverse(items)
  ordered
  |> list.map(name_of)
  |> list.unique
  |> list.sort(string.compare)
  |> list.map(fn(name) {
    #(name, list.filter(ordered, fn(item) { name_of(item) == name }))
  })
}

fn format_labels(labels: List(#(String, String))) -> String {
  case labels {
    [] -> ""
    _ -> {
      let pairs =
        list.map(labels, fn(l) { l.0 <> "=\"" <> escape_label(l.1) <> "\"" })
      "{" <> string.join(pairs, ",") <> "}"
    }
  }
}

/// Label values escape backslash, double quote and newline.
fn escape_label(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
}

fn float_to_string(f: Float) -> String {
  float.to_string(f)
}
