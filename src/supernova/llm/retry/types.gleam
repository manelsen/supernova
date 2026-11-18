//// Retry with exponential backoff for LLM calls.
////
//// Retries transient failures (network, 429, 5xx) with exponential backoff.
//// Does NOT retry 4xx client errors (except 429), validation errors.

import gleam/float
import gleam/int
import gleam/io
import gleam/string
import supernova/llm/provider

pub const default_initial_delay_ms: Int = 1000

pub const default_max_delay_ms: Int = 30_000

pub const default_max_attempts: Int = 3

pub const default_jitter_factor: Float = 0.2

pub type RetryConfig {
  RetryConfig(
    initial_delay_ms: Int,
    max_delay_ms: Int,
    max_attempts: Int,
    jitter_factor: Float,
  )
}

pub fn default_config() -> RetryConfig {
  RetryConfig(
    initial_delay_ms: default_initial_delay_ms,
    max_delay_ms: default_max_delay_ms,
    max_attempts: default_max_attempts,
    jitter_factor: default_jitter_factor,
  )
}

pub type ShouldRetry {
  ShouldRetry
  DoNotRetry(reason: String)
}

pub fn is_retryable(err: provider.LLMError) -> ShouldRetry {
  case err {
    provider.NetworkError(_) -> ShouldRetry
    provider.APIError(status, _) -> {
      case status {
        429 -> ShouldRetry
        n if n >= 500 && n < 600 -> ShouldRetry
        _ -> DoNotRetry("non-retryable status: " <> int.to_string(status))
      }
    }
    provider.ConfigError(msg) ->
      DoNotRetry("config error (not retryable): " <> msg)
    provider.ProviderNotFound(name) ->
      DoNotRetry("provider not found: " <> name)
    provider.NotImplemented(msg) -> DoNotRetry("not implemented: " <> msg)
    provider.CircuitOpen(provider_name) ->
      DoNotRetry("circuit open for provider: " <> provider_name)
  }
}

fn jittered_delay(base_ms: Int, attempt: Int, config: RetryConfig) -> Int {
  let exponential = case int.power(2, int.to_float(attempt - 1)) {
    Ok(e) -> e
    Error(_) -> 1.0
  }
  let raw_delay = int.to_float(base_ms) *. exponential
  let capped = case raw_delay >. int.to_float(config.max_delay_ms) {
    True -> config.max_delay_ms
    False -> float.round(raw_delay)
  }
  let jitter_range = float.round(int.to_float(capped) *. config.jitter_factor)
  let jitter =
    float.round(int.to_float(jitter_range) *. { float.random() *. 2.0 -. 1.0 })
  let final_delay = capped + jitter
  case final_delay < 0 {
    True -> 0
    False -> final_delay
  }
}

@external(erlang, "supernova_ledger_ffi", "sleep_ms")
fn sleep_ms(ms: Int) -> Nil

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn current_timestamp() -> Int

@external(erlang, "supernova_telemetry_ffi", "write_event")
fn write_telemetry_event(
  name: String,
  timestamp: Int,
  agent_id: String,
) -> Result(Nil, String)

fn log_retry_event(event: String, attempt: Int, ts: Int, extra: String) -> Nil {
  let _ =
    write_telemetry_event(
      event,
      ts,
      "retry:" <> int.to_string(attempt) <> ":" <> extra,
    )
  Nil
}

pub fn with_retry(
  config: RetryConfig,
  work: fn() -> Result(provider.ChatResponse, provider.LLMError),
) -> Result(provider.ChatResponse, provider.LLMError) {
  with_retry_loop(config, 1, work)
}

/// Sleep before a retry attempt, using the same capped exponential delay and
/// telemetry as `with_retry`. Callers that need per-attempt admission and
/// settlement own the retry loop and call this between attempts.
pub fn wait_before_retry(config: RetryConfig, failed_attempt: Int) -> Nil {
  let delay = jittered_delay(config.initial_delay_ms, failed_attempt, config)
  let ts = current_timestamp()
  let _ =
    log_retry_event("retry.attempt", failed_attempt, ts, int.to_string(delay))
  let _ = sleep_ms(delay)
  Nil
}

fn with_retry_loop(
  config: RetryConfig,
  attempt: Int,
  work: fn() -> Result(provider.ChatResponse, provider.LLMError),
) -> Result(provider.ChatResponse, provider.LLMError) {
  case work() {
    Ok(response) -> Ok(response)
    Error(err) -> {
      let _ =
        io.println(
          "[retry] Attempt "
          <> int.to_string(attempt)
          <> " error: "
          <> string.inspect(err),
        )
      case attempt >= config.max_attempts {
        True -> {
          let _ =
            io.println(
              "[retry] Giving up after "
              <> int.to_string(attempt)
              <> " attempts: "
              <> string.inspect(err),
            )
          Error(err)
        }
        False -> {
          case is_retryable(err) {
            ShouldRetry -> {
              let delay =
                jittered_delay(config.initial_delay_ms, attempt, config)
              let ts = current_timestamp()
              let _ =
                log_retry_event(
                  "retry.attempt",
                  attempt,
                  ts,
                  int.to_string(delay),
                )
              let _ = sleep_ms(delay)
              with_retry_loop(config, attempt + 1, work)
            }
            DoNotRetry(reason) -> {
              let ts = current_timestamp()
              let _ = log_retry_event("retry.giveup", attempt, ts, reason)
              Error(err)
            }
          }
        }
      }
    }
  }
}
