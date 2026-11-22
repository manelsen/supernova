//// Actors registered in a global are found again. The lookup used to check
//// liveness on the Subject itself, which always failed: no span was ever
//// opened and the circuit breaker was never consulted.
////
//// Each test restores the previous registration and stops its own actor, so
//// no other test runs against an actor left behind here.

import exception
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/core/executor
import supernova/core/sub_agent
import supernova/llm/circuit_breaker/actor as cb_actor
import supernova/llm/circuit_breaker/global as cb_global
import supernova/llm/provider
import supernova/metrics/actor as metrics_actor
import supernova/metrics/global as metrics_global
import supernova/tracing/actor as tracing_actor
import supernova/tracing/global as tracing_global
import supernova/tracing/types as tracing_types

pub fn tracer_is_found_after_set_test() {
  let previous = tracing_global.get_tracer()
  let assert Ok(started) =
    tracing_actor.start_linked(tracing_types.TracerConfig(
      service_name: "t",
      otlp_endpoint: "",
      sampling_rate: 1.0,
    ))
  use <- exception.defer(fn() {
    case previous {
      Some(tracer) -> tracing_global.set_tracer(tracer)
      None -> tracing_global.clear_tracer()
    }
    process.unlink(process.subject_owner(started.data) |> unwrap_pid)
    process.kill(process.subject_owner(started.data) |> unwrap_pid)
  })
  tracing_global.set_tracer(started.data)
  tracing_global.get_tracer() |> option.is_some |> should.be_true()
}

pub fn breaker_is_found_after_set_test() {
  let previous = cb_global.get_circuit_breaker()
  let assert Ok(breaker) =
    cb_actor.start(cb_actor.CircuitBreakerConfig(1, 30_000, 1))
  use <- exception.defer(fn() {
    case previous {
      Some(previous) -> cb_global.set_circuit_breaker(previous)
      None -> cb_global.clear_circuit_breaker()
    }
    cb_actor.stop(breaker)
  })
  cb_global.set_circuit_breaker(breaker)
  cb_global.get_circuit_breaker() |> option.is_some |> should.be_true()
}

fn unwrap_pid(owner: Result(process.Pid, Nil)) -> process.Pid {
  let assert Ok(pid) = owner
  pid
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

pub fn cancel_after_completion_lowers_active_agents_once_test() {
  let previous = metrics_global.get_metrics()
  let assert Ok(metrics) = metrics_actor.start()
  use <- exception.defer(fn() {
    case previous {
      Some(previous) -> metrics_global.set_metrics(previous)
      None -> metrics_global.clear_metrics()
    }
  })
  metrics_global.set_metrics(metrics)

  let assert Ok(agent) =
    sub_agent.spawn("parent-gauge", "goal", sub_agent.default_config())
  let assert Ok(_) = sub_agent.await(agent, 2000)
  let assert Ok(Nil) = sub_agent.cancel(agent)
  let assert Ok(Nil) = sub_agent.cancel(agent)

  string.contains(metrics_actor.get_metrics(metrics), "agents_active 0\n")
  |> should.be_true()
}
