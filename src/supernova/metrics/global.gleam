//// Global metrics registry.
////
//// Provides a process-dictionary backed global reference to the metrics actor.
//// Allows instrumentation from anywhere without passing the handle explicitly.

import gleam/erlang/process.{type Subject}
import gleam/option

import supernova/metrics/actor as metrics_actor

pub type Metrics =
  Subject(metrics_actor.MetricsCommand)

@external(erlang, "erlang", "put")
fn erlang_put(key: String, value: any) -> any

@external(erlang, "erlang", "get")
fn erlang_get(key: String) -> any

@external(erlang, "erlang", "is_process_alive")
fn is_process_alive(pid: any) -> Bool

const metrics_key = "supernova_global_metrics"

const metrics_marker = "supernova_metrics_active"

pub fn set_metrics(metrics: Metrics) -> Nil {
  erlang_put(metrics_key, metrics)
  erlang_put(metrics_marker, True)
  Nil
}

pub fn get_metrics() -> option.Option(Metrics) {
  let marker = erlang_get(metrics_marker)
  case marker {
    True -> {
      let metrics = erlang_get(metrics_key)
      case is_process_alive(metrics) {
        True -> option.Some(metrics)
        False -> option.None
      }
    }
    _ -> option.None
  }
}
