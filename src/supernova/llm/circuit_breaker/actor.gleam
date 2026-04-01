//// Circuit breaker actor for LLM provider calls.
////
//// Manages per-provider circuit breakers with states: Closed -> Open -> HalfOpen.
//// Thread-safe actor-based state management.

import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/llm/circuit_breaker

pub type CircuitBreakerActor =
  Subject(CircuitBreakerCommand)

pub type CircuitBreakerConfig {
  CircuitBreakerConfig(
    failure_threshold: Int,
    recovery_timeout_ms: Int,
    half_open_max_calls: Int,
  )
}

pub type CircuitBreakerCommand {
  CheckAndCall(provider: String, reply_to: Subject(CheckResult))
  RecordSuccess(provider: String, reply_to: Subject(Nil))
  RecordFailure(provider: String, reply_to: Subject(Nil))
  GetState(provider: String, reply_to: Subject(CircuitBreakerState))
  Stop(reply_to: Subject(Nil))
}

pub type CheckResult {
  Allowed
  Blocked(reason: String)
}

pub type CircuitBreakerState {
  CircuitBreakerState(state: circuit_breaker.CircuitState)
}

type BreakerMap =
  dict.Dict(String, circuit_breaker.CircuitBreaker)

fn to_circuit_config(
  config: CircuitBreakerConfig,
) -> circuit_breaker.CircuitConfig {
  circuit_breaker.CircuitConfig(
    failure_threshold: config.failure_threshold,
    recovery_timeout_ms: config.recovery_timeout_ms,
    half_open_max_calls: config.half_open_max_calls,
  )
}

fn handle_message(
  state: BreakerMap,
  message: CircuitBreakerCommand,
  config: CircuitBreakerConfig,
) -> actor.Next(BreakerMap, CircuitBreakerCommand) {
  case message {
    CheckAndCall(provider, reply_to) -> {
      let cc = to_circuit_config(config)
      let breaker = get_or_create_breaker(state, provider, cc)
      case circuit_breaker.is_call_allowed(breaker, cc) {
        True -> {
          actor.send(reply_to, Allowed)
          actor.continue(state)
        }
        False -> {
          actor.send(reply_to, Blocked("circuit_open"))
          actor.continue(state)
        }
      }
    }
    RecordSuccess(provider, reply_to) -> {
      let cc = to_circuit_config(config)
      let breaker = get_or_create_breaker(state, provider, cc)
      let updated = circuit_breaker.record_success(breaker, cc)
      let new_state = update_breaker(state, provider, updated)
      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }
    RecordFailure(provider, reply_to) -> {
      let cc = to_circuit_config(config)
      let breaker = get_or_create_breaker(state, provider, cc)
      let updated = circuit_breaker.record_failure(breaker, cc)
      let new_state = update_breaker(state, provider, updated)
      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }
    GetState(provider, reply_to) -> {
      let cc = to_circuit_config(config)
      let breaker = get_or_create_breaker(state, provider, cc)
      actor.send(reply_to, CircuitBreakerState(state: breaker.state))
      actor.continue(state)
    }
    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

fn get_or_create_breaker(
  state: BreakerMap,
  provider: String,
  config: circuit_breaker.CircuitConfig,
) -> circuit_breaker.CircuitBreaker {
  case dict.get(state, provider) {
    Ok(breaker) -> breaker
    Error(_) -> circuit_breaker.new(provider, config)
  }
}

fn update_breaker(
  state: BreakerMap,
  provider: String,
  breaker: circuit_breaker.CircuitBreaker,
) -> BreakerMap {
  dict.insert(state, provider, breaker)
}

pub fn start(
  config: CircuitBreakerConfig,
) -> Result(CircuitBreakerActor, actor.StartError) {
  case start_linked(config) {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Start and return the full Started record (for use with supervisors).
pub fn start_linked(
  config: CircuitBreakerConfig,
) -> Result(actor.Started(CircuitBreakerActor), actor.StartError) {
  let initial: BreakerMap = dict.new()
  actor.new(initial)
  |> actor.on_message(fn(state, message) {
    handle_message(state, message, config)
  })
  |> actor.start
}

pub fn check_and_call(
  breaker: CircuitBreakerActor,
  provider: String,
) -> CheckResult {
  actor.call(breaker, waiting: 5000, sending: CheckAndCall(provider, _))
}

pub fn record_success(breaker: CircuitBreakerActor, provider: String) {
  actor.call(breaker, waiting: 5000, sending: RecordSuccess(provider, _))
}

pub fn record_failure(breaker: CircuitBreakerActor, provider: String) {
  actor.call(breaker, waiting: 5000, sending: RecordFailure(provider, _))
}

pub fn stop(breaker: CircuitBreakerActor) {
  actor.call(breaker, waiting: 5000, sending: Stop)
}
