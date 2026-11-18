import gleam/erlang/process
import gleam/option
import gleeunit
import gleeunit/should
import supernova/llm/provider
import supernova/llm/retry/types as retry_types

pub fn main() {
  gleeunit.main()
}

fn sample_response() -> provider.ChatResponse {
  provider.ChatResponse(
    role: "assistant",
    content: "ok",
    tool_calls: option.None,
    reasoning_content: option.None,
  )
}

pub fn default_config_has_expected_values_test() {
  let cfg = retry_types.default_config()
  cfg.initial_delay_ms |> should.equal(retry_types.default_initial_delay_ms)
  cfg.max_delay_ms |> should.equal(retry_types.default_max_delay_ms)
  cfg.max_attempts |> should.equal(retry_types.default_max_attempts)
  cfg.jitter_factor |> should.equal(retry_types.default_jitter_factor)
}

pub fn is_retryable_classifies_errors_test() {
  retry_types.is_retryable(provider.NetworkError(reason: "down"))
  |> should.equal(retry_types.ShouldRetry)

  retry_types.is_retryable(provider.APIError(status: 429, message: "rate"))
  |> should.equal(retry_types.ShouldRetry)

  retry_types.is_retryable(provider.APIError(status: 503, message: "oops"))
  |> should.equal(retry_types.ShouldRetry)

  retry_types.is_retryable(provider.APIError(status: 400, message: "bad"))
  |> should.equal(retry_types.DoNotRetry("non-retryable status: 400"))
}

pub fn with_retry_returns_success_immediately_test() {
  let cfg =
    retry_types.RetryConfig(
      initial_delay_ms: 0,
      max_delay_ms: 0,
      max_attempts: 3,
      jitter_factor: 0.0,
    )

  retry_types.with_retry(cfg, fn() { Ok(sample_response()) })
  |> should.equal(Ok(sample_response()))
}

pub fn with_retry_retries_retryable_errors_until_max_attempts_test() {
  let calls = process.new_subject()
  let cfg =
    retry_types.RetryConfig(
      initial_delay_ms: 0,
      max_delay_ms: 0,
      max_attempts: 2,
      jitter_factor: 0.0,
    )

  let result =
    retry_types.with_retry(cfg, fn() {
      process.send(calls, Nil)
      Error(provider.NetworkError(reason: "down"))
    })

  result |> should.equal(Error(provider.NetworkError(reason: "down")))
  process.receive(calls, within: 100) |> should.equal(Ok(Nil))
  process.receive(calls, within: 100) |> should.equal(Ok(Nil))
}

pub fn with_retry_does_not_retry_non_retryable_errors_test() {
  let calls = process.new_subject()
  let cfg =
    retry_types.RetryConfig(
      initial_delay_ms: 0,
      max_delay_ms: 0,
      max_attempts: 3,
      jitter_factor: 0.0,
    )

  let result =
    retry_types.with_retry(cfg, fn() {
      process.send(calls, Nil)
      Error(provider.ConfigError(reason: "missing key"))
    })

  result |> should.equal(Error(provider.ConfigError(reason: "missing key")))
  process.receive(calls, within: 100) |> should.equal(Ok(Nil))
  process.receive(calls, within: 100) |> should.equal(Error(Nil))
}
