import gleam/option.{Some}
import gleeunit
import gleeunit/should
import supernova/llm/circuit_breaker as cb

pub fn main() {
  gleeunit.main()
}

fn test_config() -> cb.CircuitConfig {
  cb.CircuitConfig(
    failure_threshold: 2,
    recovery_timeout_ms: 1000,
    half_open_max_calls: 2,
  )
}

pub fn new_breaker_starts_closed_test() {
  let breaker = cb.new("openai", test_config())

  breaker.state |> should.equal(cb.CircuitClosed)
  breaker.failure_count |> should.equal(0)
  breaker.success_count |> should.equal(0)
}

pub fn record_failure_below_threshold_stays_closed_test() {
  let breaker = cb.new("openai", test_config())
  let next = cb.record_failure(breaker, test_config())

  next.state |> should.equal(cb.CircuitClosed)
  next.failure_count |> should.equal(1)
}

pub fn record_failure_at_threshold_opens_circuit_test() {
  let breaker =
    cb.CircuitBreaker(
      name: "openai",
      state: cb.CircuitClosed,
      failure_count: 1,
      success_count: 0,
      last_failure_time_ms: 0,
      cooldown_ms: 1000,
    )
  let next = cb.record_failure(breaker, test_config())

  next.state |> should.equal(cb.CircuitOpen)
  next.failure_count |> should.equal(2)
}

pub fn is_call_allowed_open_before_timeout_returns_false_test() {
  let breaker =
    cb.CircuitBreaker(
      name: "openai",
      state: cb.CircuitOpen,
      failure_count: 2,
      success_count: 0,
      last_failure_time_ms: 9_999_999_999_999,
      cooldown_ms: 1000,
    )

  cb.is_call_allowed(breaker, test_config())
  |> should.equal(False)
}

pub fn is_call_allowed_open_after_timeout_returns_true_test() {
  let breaker =
    cb.CircuitBreaker(
      name: "openai",
      state: cb.CircuitOpen,
      failure_count: 2,
      success_count: 0,
      last_failure_time_ms: 0,
      cooldown_ms: 1000,
    )

  cb.is_call_allowed(breaker, test_config())
  |> should.equal(True)
}

pub fn record_success_in_half_open_closes_after_limit_test() {
  let breaker =
    cb.CircuitBreaker(
      name: "openai",
      state: cb.CircuitHalfOpen,
      failure_count: 0,
      success_count: 1,
      last_failure_time_ms: 0,
      cooldown_ms: 1000,
    )
  let next = cb.record_success(breaker, test_config())

  next.state |> should.equal(cb.CircuitClosed)
  next.success_count |> should.equal(0)
}

pub fn record_failure_in_half_open_reopens_immediately_test() {
  let breaker =
    cb.CircuitBreaker(
      name: "openai",
      state: cb.CircuitHalfOpen,
      failure_count: 0,
      success_count: 1,
      last_failure_time_ms: 0,
      cooldown_ms: 1000,
    )
  let next = cb.record_failure(breaker, test_config())

  next.state |> should.equal(cb.CircuitOpen)
  next.failure_count |> should.equal(1)
}

pub fn state_name_maps_all_states_test() {
  cb.state_name(cb.CircuitClosed) |> should.equal("closed")
  cb.state_name(cb.CircuitOpen) |> should.equal("open")
  cb.state_name(cb.CircuitHalfOpen) |> should.equal("half_open")

  let breaker = cb.new("openai", test_config())
  cb.is_call_allowed(breaker, test_config()) |> should.equal(True)
  breaker.last_failure_time_ms |> should.equal(0)
  breaker.cooldown_ms |> should.equal(1000)
  Some(breaker.name) |> should.equal(Some("openai"))
}
