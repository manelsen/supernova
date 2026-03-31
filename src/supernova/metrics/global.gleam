//// Global metrics registry.
////
//// Provides a persistent_term backed global reference to the metrics actor.
//// Accessible from any process without passing the handle explicitly.

import gleam/erlang/process.{type Subject}
import gleam/option

import supernova/metrics/actor as metrics_actor

pub type Metrics =
  Subject(metrics_actor.MetricsCommand)

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: any) -> Nil

@external(erlang, "supernova_global_ffi", "global_get")
fn global_get(key: String) -> any

@external(erlang, "supernova_global_ffi", "global_has")
fn global_has(key: String) -> Bool

@external(erlang, "erlang", "is_process_alive")
fn is_process_alive(pid: any) -> Bool

const metrics_key = "supernova_global_metrics"

pub fn set_metrics(metrics: Metrics) -> Nil {
  global_put(metrics_key, metrics)
}

pub fn get_metrics() -> option.Option(Metrics) {
  case global_has(metrics_key) {
    True -> {
      let metrics = global_get(metrics_key)
      case is_process_alive(metrics) {
        True -> option.Some(metrics)
        False -> option.None
      }
    }
    False -> option.None
  }
}
