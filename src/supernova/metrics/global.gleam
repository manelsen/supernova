// Global metrics registry.
//
// Provides a persistent_term backed global reference to the metrics actor.
// Accessible from any process without passing the handle explicitly.

import gleam/erlang/process.{type Subject}
import gleam/option

import supernova/metrics/actor as metrics_actor

pub type Metrics =
  Subject(metrics_actor.MetricsCommand)

@external(erlang, "supernova_global_ffi", "global_erase")
fn global_erase(key: String) -> Nil

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: any) -> Nil

@external(erlang, "supernova_global_ffi", "global_get")
fn global_get(key: String) -> any

@external(erlang, "supernova_global_ffi", "global_has")
fn global_has(key: String) -> Bool

@external(erlang, "supernova_global_ffi", "safe_is_process_alive")
pub fn safe_check_alive(pid: any) -> Bool

const metrics_key = "supernova_global_metrics"

pub fn set_metrics(metrics: Metrics) -> Nil {
  global_put(metrics_key, metrics)
}

pub fn get_metrics() -> option.Option(Metrics) {
  case global_has(metrics_key) {
    True -> {
      let metrics = global_get(metrics_key)
      option.Some(metrics)
    }
    False -> option.None
  }
}

/// Forget the registered actor (tests restore the previous state with it).
pub fn clear_metrics() -> Nil {
  global_erase(metrics_key)
}
