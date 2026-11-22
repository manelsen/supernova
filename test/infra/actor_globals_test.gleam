//// Actors registered in a global are found again. The lookup used to check
//// liveness on the Subject itself, which always failed: no span was ever
//// opened and the circuit breaker was never consulted.

import gleam/option
import gleeunit/should
import supernova/core/executor
import supernova/llm/circuit_breaker/actor as cb_actor
import supernova/llm/circuit_breaker/global as cb_global
import supernova/llm/provider
import supernova/tracing/actor as tracing_actor
import supernova/tracing/global as tracing_global
import supernova/tracing/types as tracing_types

pub fn tracer_is_found_after_set_test() {
  let assert Ok(started) =
    tracing_actor.start_linked(tracing_types.TracerConfig(
      service_name: "t",
      otlp_endpoint: "",
      sampling_rate: 1.0,
    ))
  tracing_global.set_tracer(started.data)
  tracing_global.get_tracer() |> option.is_some |> should.be_true()
}

pub fn breaker_is_found_after_set_test() {
  let assert Ok(breaker) =
    cb_actor.start(cb_actor.CircuitBreakerConfig(1, 30_000, 1))
  cb_global.set_circuit_breaker(breaker)
  cb_global.get_circuit_breaker() |> option.is_some |> should.be_true()
}

pub fn only_unavailability_counts_against_the_breaker_test() {
  executor.provider_unavailable(provider.NetworkError("econnrefused"))
  |> should.be_true()
  executor.provider_unavailable(provider.APIError(503, "unavailable"))
  |> should.be_true()
  executor.provider_unavailable(provider.APIError(429, "slow down"))
  |> should.be_true()
  executor.provider_unavailable(provider.APIError(400, "context too long"))
  |> should.be_false()
  executor.provider_unavailable(provider.APIError(401, "bad key"))
  |> should.be_false()
  executor.provider_unavailable(provider.ConfigError("x")) |> should.be_false()
}
