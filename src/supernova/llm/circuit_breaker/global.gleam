//// Global circuit breaker registry.
////
//// Provides a process-dictionary backed global reference to the circuit breaker actor.

import gleam/erlang/process.{type Subject}
import gleam/option

import supernova/llm/circuit_breaker/actor as cb_actor

pub type CircuitBreaker =
  Subject(cb_actor.CircuitBreakerCommand)

@external(erlang, "erlang", "put")
fn erlang_put(key: String, value: any) -> any

@external(erlang, "erlang", "get")
fn erlang_get(key: String) -> any

@external(erlang, "erlang", "is_process_alive")
fn is_process_alive(pid: any) -> Bool

const cb_key = "supernova_global_circuit_breaker"

const cb_marker = "supernova_cb_active"

pub fn set_circuit_breaker(cb: CircuitBreaker) -> Nil {
  erlang_put(cb_key, cb)
  erlang_put(cb_marker, True)
  Nil
}

pub fn get_circuit_breaker() -> option.Option(CircuitBreaker) {
  let marker = erlang_get(cb_marker)
  case marker {
    True -> {
      let cb = erlang_get(cb_key)
      case is_process_alive(cb) {
        True -> option.Some(cb)
        False -> option.None
      }
    }
    _ -> option.None
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
