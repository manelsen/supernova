//// Global tracing registry.
////
//// Provides a process-dictionary backed global reference to the tracer actor.
//// Allows tracing from anywhere without passing the handle explicitly.

import gleam/erlang/process.{type Subject}
import gleam/option

import supernova/tracing/actor as tracing_actor
import supernova/tracing/types as tracing_types

pub type Tracer =
  Subject(tracing_types.TelemetryCommand)

@external(erlang, "erlang", "put")
fn erlang_put(key: String, value: any) -> any

@external(erlang, "erlang", "get")
fn erlang_get(key: String) -> any

@external(erlang, "erlang", "is_process_alive")
fn is_process_alive(pid: any) -> Bool

const tracer_key = "supernova_global_tracer"

const tracer_marker = "supernova_tracer_active"

pub fn set_tracer(tracer: Tracer) -> Nil {
  erlang_put(tracer_key, tracer)
  erlang_put(tracer_marker, True)
  Nil
}

pub fn get_tracer() -> option.Option(Tracer) {
  let marker = erlang_get(tracer_marker)
  case marker {
    True -> {
      let tracer = erlang_get(tracer_key)
      case is_process_alive(tracer) {
        True -> option.Some(tracer)
        False -> option.None
      }
    }
    _ -> option.None
  }
}

pub type Span =
  tracing_types.Span

pub fn start_span(
  name: String,
  kind: tracing_types.SpanKind,
  parent_context: option.Option(tracing_types.SpanContext),
) -> option.Option(tracing_types.Span) {
  case get_tracer() {
    option.Some(tracer) -> {
      case tracing_actor.start_span(tracer, name, kind, parent_context) {
        Ok(span) -> option.Some(span)
        Error(_) -> option.None
      }
    }
    option.None -> option.None
  }
}

pub fn end_span(span: tracing_types.Span, status: tracing_types.SpanStatus) {
  case get_tracer() {
    option.Some(tracer) ->
      tracing_actor.end_span(tracer, span.span_context.span_id, status)
    option.None -> Nil
  }
}

pub fn add_span_event(
  span: tracing_types.Span,
  event_name: String,
  attributes: List(#(String, String)),
) {
  case get_tracer() {
    option.Some(tracer) ->
      tracing_actor.add_span_event(
        tracer,
        span.span_context.span_id,
        event_name,
        attributes,
      )
    option.None -> Nil
  }
}

pub fn set_span_attributes(
  span: tracing_types.Span,
  attributes: List(#(String, String)),
) {
  case get_tracer() {
    option.Some(tracer) ->
      tracing_actor.set_span_attributes(
        tracer,
        span.span_context.span_id,
        attributes,
      )
    option.None -> Nil
  }
}
