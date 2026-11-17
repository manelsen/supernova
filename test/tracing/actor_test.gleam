import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import supernova/tracing/actor as tracing_actor
import supernova/tracing/types as tracing_types

pub fn main() {
  gleeunit.main()
}

fn tracer_config() -> tracing_types.TracerConfig {
  tracing_types.TracerConfig(
    service_name: "supernova-test",
    otlp_endpoint: "http://localhost:4318",
    sampling_rate: 1.0,
  )
}

pub fn start_span_event_attributes_end_and_flush_test() {
  let assert Ok(tracer) = tracing_actor.start(tracer_config())

  let assert Ok(root_span) =
    tracing_actor.start_span(
      tracer,
      "root",
      tracing_types.SpanKindInternal,
      None,
    )

  let assert Ok(child_span) =
    tracing_actor.start_span(
      tracer,
      "child",
      tracing_types.SpanKindClient,
      Some(root_span.span_context),
    )

  tracing_actor.add_span_event(
    tracer,
    child_span.span_context.span_id,
    "request_sent",
    [#("method", "POST")],
  )
  tracing_actor.set_span_attributes(tracer, child_span.span_context.span_id, [
    #("http.status_code", "200"),
  ])
  tracing_actor.end_span(
    tracer,
    child_span.span_context.span_id,
    tracing_types.SpanStatusOk,
  )
  tracing_actor.end_span(
    tracer,
    root_span.span_context.span_id,
    tracing_types.SpanStatusError("timeout"),
  )
  tracing_actor.force_flush(tracer) |> should.equal(Nil)
  tracing_actor.shutdown(tracer) |> should.equal(Nil)
}

pub fn operations_on_unknown_span_do_not_crash_test() {
  let assert Ok(tracer) = tracing_actor.start(tracer_config())
  tracing_actor.add_span_event(tracer, "missing", "ignored", [])
  tracing_actor.set_span_attributes(tracer, "missing", [#("k", "v")])
  tracing_actor.end_span(tracer, "missing", tracing_types.SpanStatusUnset)
  tracing_actor.shutdown(tracer) |> should.equal(Nil)
}
