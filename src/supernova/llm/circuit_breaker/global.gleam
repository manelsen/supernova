//// Global circuit breaker registry.
////
//// Provides a persistent_term backed global reference to the circuit breaker actor.

import gleam/erlang/process.{type Subject}
import gleam/option

import supernova/llm/circuit_breaker/actor as cb_actor

pub type CircuitBreaker =
  Subject(cb_actor.CircuitBreakerCommand)

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: any) -> Nil

@external(erlang, "supernova_global_ffi", "global_get")
fn global_get(key: String) -> any

@external(erlang, "supernova_global_ffi", "global_has")
fn global_has(key: String) -> Bool

@external(erlang, "erlang", "is_process_alive")
fn is_process_alive(pid: any) -> Bool

const cb_key = "supernova_global_circuit_breaker"

pub fn set_circuit_breaker(cb: CircuitBreaker) -> Nil {
  global_put(cb_key, cb)
}

pub fn get_circuit_breaker() -> option.Option(CircuitBreaker) {
  case global_has(cb_key) {
    True -> {
      let cb = global_get(cb_key)
      case is_process_alive(cb) {
        True -> option.Some(cb)
        False -> option.None
      }
    }
    False -> option.None
  }
}

pub type CheckResult =
  cb_actor.CheckResult

pub fn check_and_call(provider: String) -> cb_actor.CheckResult {
  case get_circuit_breaker() {
    option.Some(cb) -> cb_actor.check_and_call(cb, provider)
    option.None -> cb_actor.Allowed
  }
}

pub fn record_success(provider: String) {
  case get_circuit_breaker() {
    option.Some(cb) -> cb_actor.record_success(cb, provider)
    option.None -> Nil
  }
}

pub fn record_failure(provider: String) {
  case get_circuit_breaker() {
    option.Some(cb) -> cb_actor.record_failure(cb, provider)
    option.None -> Nil
  }
}
