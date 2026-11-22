//// The breaker goes through its whole cycle through the actor, which is how
//// the executor uses it.

import gleeunit/should
import supernova/llm/circuit_breaker as cb
import supernova/llm/circuit_breaker/actor as cb_actor

@external(erlang, "supernova_mock_ffi", "clock_set")
fn clock_set(now: Int) -> Nil

@external(erlang, "supernova_mock_ffi", "clock_now")
fn clock_now() -> Int

/// Recovery takes 30 s of test clock; no test waits for real time.
fn start() -> cb_actor.CircuitBreakerActor {
  clock_set(1_000_000)
  let assert Ok(breaker) =
    cb_actor.start_with_clock(
      cb_actor.CircuitBreakerConfig(
        failure_threshold: 3,
        recovery_timeout_ms: 30_000,
        half_open_max_calls: 2,
      ),
      clock_now,
    )
  breaker
}

fn advance(ms: Int) -> Nil {
  clock_set(clock_now() + ms)
}

fn state(breaker, provider) -> cb.CircuitState {
  cb_actor.get_state(breaker, provider)
}

fn fail_times(breaker, provider, n: Int) -> Nil {
  case n {
    0 -> Nil
    _ -> {
      cb_actor.record_failure(breaker, provider)
      fail_times(breaker, provider, n - 1)
    }
  }
}

pub fn opens_after_threshold_and_blocks_test() {
  let breaker = start()
  fail_times(breaker, "mistral", 2)
  cb_actor.check_and_call(breaker, "mistral") |> should.equal(cb_actor.Allowed)
  fail_times(breaker, "mistral", 1)
  state(breaker, "mistral") |> should.equal(cb.CircuitOpen)
  cb_actor.check_and_call(breaker, "mistral")
  |> should.equal(cb_actor.Blocked("circuit_open"))
}

pub fn recovers_to_closed_after_half_open_successes_test() {
  let breaker = start()
  fail_times(breaker, "mistral", 3)
  advance(30_000)

  cb_actor.check_and_call(breaker, "mistral") |> should.equal(cb_actor.Allowed)
  state(breaker, "mistral") |> should.equal(cb.CircuitHalfOpen)
  cb_actor.record_success(breaker, "mistral")
  cb_actor.record_success(breaker, "mistral")
  state(breaker, "mistral") |> should.equal(cb.CircuitClosed)
}

pub fn failure_in_half_open_reopens_and_blocks_again_test() {
  let breaker = start()
  fail_times(breaker, "mistral", 3)
  advance(30_000)

  cb_actor.check_and_call(breaker, "mistral") |> should.equal(cb_actor.Allowed)
  cb_actor.record_failure(breaker, "mistral")
  state(breaker, "mistral") |> should.equal(cb.CircuitOpen)
  cb_actor.check_and_call(breaker, "mistral")
  |> should.equal(cb_actor.Blocked("circuit_open"))

  // One millisecond short of recovery, it still blocks.
  advance(29_999)
  cb_actor.check_and_call(breaker, "mistral")
  |> should.equal(cb_actor.Blocked("circuit_open"))
  advance(1)
  cb_actor.check_and_call(breaker, "mistral") |> should.equal(cb_actor.Allowed)
}

pub fn breaker_works_again_after_recovering_test() {
  let breaker = start()
  fail_times(breaker, "mistral", 3)
  advance(30_000)
  let assert cb_actor.Allowed = cb_actor.check_and_call(breaker, "mistral")
  cb_actor.record_success(breaker, "mistral")
  cb_actor.record_success(breaker, "mistral")

  fail_times(breaker, "mistral", 3)
  cb_actor.check_and_call(breaker, "mistral")
  |> should.equal(cb_actor.Blocked("circuit_open"))
}

pub fn providers_are_independent_test() {
  let breaker = start()
  fail_times(breaker, "mistral", 3)
  cb_actor.check_and_call(breaker, "anthropic")
  |> should.equal(cb_actor.Allowed)
}
