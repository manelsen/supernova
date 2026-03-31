//// OpenTelemetry tracing — simplified implementation.
////
//// Provides span creation and logging for observability.
//// Spans are logged to stdout; full OTLP export can be wired later.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string

import supernova/tracing/types as tracing_types

pub type Tracer =
  Subject(tracing_types.TelemetryCommand)

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn current_timestamp() -> Int

fn handle_message(
  state: tracing_types.TracerState,
  message: tracing_types.TelemetryCommand,
) -> actor.Next(tracing_types.TracerState, tracing_types.TelemetryCommand) {
  case message {
    tracing_types.StartSpan(name, kind, parent_context, reply_to) -> {
      let now = current_timestamp()
      let span_ctx = tracing_types.create_span_context()
      let kind_str = case kind {
        tracing_types.SpanKindInternal -> "internal"
        tracing_types.SpanKindServer -> "server"
        tracing_types.SpanKindClient -> "client"
        tracing_types.SpanKindProducer -> "producer"
        tracing_types.SpanKindConsumer -> "consumer"
      }
      let parent_id = case parent_context {
        Some(ctx) -> ctx.span_id
        None -> "none"
      }
      io.println(
        "[TRACE] span started: name="
        <> name
        <> " kind="
        <> kind_str
        <> " trace_id="
        <> span_ctx.trace_id
        <> " parent="
        <> parent_id,
      )
      let span =
        tracing_types.Span(
          name: name,
          span_context: span_ctx,
          kind: kind,
          start_time_ms: now,
          end_time_ms: 0,
          attributes: [],
          events: [],
          status: tracing_types.SpanStatusUnset,
          parent_span_id: Some(parent_id),
        )
      let new_active =
        list.prepend(state.active_spans, #(span_ctx.span_id, span))
      let new_state =
        tracing_types.TracerState(
          config: state.config,
          active_spans: new_active,
          pending_exports: state.pending_exports,
        )
      actor.send(reply_to, Ok(span))
      actor.continue(new_state)
    }
    tracing_types.EndSpan(span_id, status) -> {
      let now = current_timestamp()
      case find_span(state.active_spans, span_id) {
        Ok(span) -> {
          let status_str = case status {
            tracing_types.SpanStatusUnset -> "unset"
            tracing_types.SpanStatusOk -> "ok"
            tracing_types.SpanStatusError(e) -> "error: " <> e
          }
          let duration = now - span.start_time_ms
          io.println(
            "[TRACE] span ended: "
            <> span.name
            <> " duration_ms="
            <> int.to_string(duration)
            <> " status="
            <> status_str,
          )
          let new_active = remove_span(state.active_spans, span_id)
          actor.continue(tracing_types.TracerState(
            config: state.config,
            active_spans: new_active,
            pending_exports: state.pending_exports,
          ))
        }
        Error(Nil) -> actor.continue(state)
      }
    }
    tracing_types.AddSpanEvent(span_id, event_name, attributes) -> {
      case find_span(state.active_spans, span_id) {
        Ok(span) -> {
          let now = current_timestamp()
          let attrs_str =
            string.join(list.map(attributes, fn(a) { a.0 <> "=" <> a.1 }), ", ")
          io.println(
            "[TRACE] event: "
            <> span.name
            <> "."
            <> event_name
            <> " "
            <> attrs_str,
          )
          let new_event =
            tracing_types.SpanEvent(
              name: event_name,
              timestamp_ms: now,
              attributes: attributes,
            )
          let updated_span =
            tracing_types.Span(
              name: span.name,
              span_context: span.span_context,
              kind: span.kind,
              start_time_ms: span.start_time_ms,
              end_time_ms: span.end_time_ms,
              attributes: span.attributes,
              events: list.prepend(span.events, new_event),
              status: span.status,
              parent_span_id: span.parent_span_id,
            )
          let new_spans = update_span(state.active_spans, span_id, updated_span)
          actor.continue(tracing_types.TracerState(
            config: state.config,
            active_spans: new_spans,
            pending_exports: state.pending_exports,
          ))
        }
        Error(Nil) -> actor.continue(state)
      }
    }
    tracing_types.SetSpanAttributes(span_id, attributes) -> {
      case find_span(state.active_spans, span_id) {
        Ok(span) -> {
          let merged = list.append(span.attributes, attributes)
          let updated_span =
            tracing_types.Span(
              name: span.name,
              span_context: span.span_context,
              kind: span.kind,
              start_time_ms: span.start_time_ms,
              end_time_ms: span.end_time_ms,
              attributes: merged,
              events: span.events,
              status: span.status,
              parent_span_id: span.parent_span_id,
            )
          let new_spans = update_span(state.active_spans, span_id, updated_span)
          actor.continue(tracing_types.TracerState(
            config: state.config,
            active_spans: new_spans,
            pending_exports: state.pending_exports,
          ))
        }
        Error(Nil) -> actor.continue(state)
      }
    }
    tracing_types.ForceFlush(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.continue(state)
    }
    tracing_types.Shutdown(reply_to) -> {
      io.println("[TRACE] tracer shutdown")
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

fn find_span(
  spans: List(#(String, tracing_types.Span)),
  span_id: String,
) -> Result(tracing_types.Span, Nil) {
  case spans {
    [] -> Error(Nil)
    [#(id, span), ..rest] -> {
      case id == span_id {
        True -> Ok(span)
        False -> find_span(rest, span_id)
      }
    }
  }
}

fn remove_span(
  spans: List(#(String, tracing_types.Span)),
  span_id: String,
) -> List(#(String, tracing_types.Span)) {
  list.filter(spans, fn(s) { s.0 != span_id })
}

fn update_span(
  spans: List(#(String, tracing_types.Span)),
  span_id: String,
  new_span: tracing_types.Span,
) -> List(#(String, tracing_types.Span)) {
  list.map(spans, fn(s) {
    case s.0 == span_id {
      True -> #(span_id, new_span)
      False -> s
    }
  })
}

pub fn start(
  config: tracing_types.TracerConfig,
) -> Result(Tracer, actor.StartError) {
  let initial =
    tracing_types.TracerState(
      config: config,
      active_spans: [],
      pending_exports: [],
    )
  case
    actor.new(initial)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

pub fn start_span(
  tracer: Tracer,
  name: String,
  kind: tracing_types.SpanKind,
  parent_context: Option(tracing_types.SpanContext),
) -> Result(tracing_types.Span, String) {
  actor.call(tracer, waiting: 5000, sending: tracing_types.StartSpan(
    name: name,
    kind: kind,
    parent_context: parent_context,
    reply_to: _,
  ))
}

pub fn end_span(
  tracer: Tracer,
  span_id: String,
  status: tracing_types.SpanStatus,
) {
  actor.send(tracer, tracing_types.EndSpan(span_id: span_id, status: status))
}

pub fn add_span_event(
  tracer: Tracer,
  span_id: String,
  event_name: String,
  attributes: List(#(String, String)),
) {
  actor.send(
    tracer,
    tracing_types.AddSpanEvent(
      span_id: span_id,
      name: event_name,
      attributes: attributes,
    ),
  )
}

pub fn set_span_attributes(
  tracer: Tracer,
  span_id: String,
  attributes: List(#(String, String)),
) {
  actor.send(
    tracer,
    tracing_types.SetSpanAttributes(span_id: span_id, attributes: attributes),
  )
}

pub fn force_flush(tracer: Tracer) {
  actor.call(tracer, waiting: 5000, sending: tracing_types.ForceFlush)
}

pub fn shutdown(tracer: Tracer) {
  actor.send(tracer, tracing_types.Shutdown(reply_to: process.new_subject()))
}
