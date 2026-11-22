// Global circuit breaker registry.
//
// Provides a persistent_term backed global reference to the circuit breaker actor.

import gleam/erlang/process.{type Subject}
import gleam/option

import supernova/llm/circuit_breaker/actor as cb_actor

pub type CircuitBreaker =
  Subject(cb_actor.CircuitBreakerCommand)

@external(erlang, "supernova_global_ffi", "global_erase")
fn global_erase(key: String) -> Nil

@external(erlang, "supernova_global_ffi", "global_lookup")
fn global_lookup(key: String) -> Result(a, Nil)

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: any) -> Nil

const cb_key = "supernova_global_circuit_breaker"

pub fn set_circuit_breaker(cb: CircuitBreaker) -> Nil {
  global_put(cb_key, cb)
}

pub fn get_circuit_breaker() -> option.Option(CircuitBreaker) {
  case global_lookup(cb_key) {
    Ok(cb) ->
      case subject_alive(cb) {
        True -> option.Some(cb)
        False -> option.None
      }
    Error(Nil) -> option.None
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

/// A global holds a `Subject`, not a pid: ask its owner process whether it
/// is alive. (`erlang:is_process_alive` on a Subject raises, which made every
/// lookup report the actor as missing.)
fn subject_alive(subject: process.Subject(message)) -> Bool {
  case process.subject_owner(subject) {
    Ok(pid) -> process.is_alive(pid)
    Error(_) -> False
  }
}

/// Forget the registered actor (tests restore the previous state with it).
pub fn clear_circuit_breaker() -> Nil {
  global_erase(cb_key)
}
