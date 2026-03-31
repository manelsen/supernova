//// OpenTelemetry tracing types.
////
//// Provides span, span context, and tracer configuration.

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}

pub type SpanContext {
  SpanContext(
    trace_id: String,
    span_id: String,
    trace_flags: Int,
    trace_state: String,
  )
}

pub type SpanKind {
  SpanKindInternal
  SpanKindServer
  SpanKindClient
  SpanKindProducer
  SpanKindConsumer
}

pub type SpanStatus {
  SpanStatusUnset
  SpanStatusOk
  SpanStatusError(description: String)
}

pub type Span {
  Span(
    name: String,
    span_context: SpanContext,
    kind: SpanKind,
    start_time_ms: Int,
    end_time_ms: Int,
    attributes: List(#(String, String)),
    events: List(SpanEvent),
    status: SpanStatus,
    parent_span_id: Option(String),
  )
}

pub type SpanEvent {
  SpanEvent(
    name: String,
    timestamp_ms: Int,
    attributes: List(#(String, String)),
  )
}

pub type TracerConfig {
  TracerConfig(
    service_name: String,
    otlp_endpoint: String,
    sampling_rate: Float,
  )
}

pub type TelemetryCommand {
  StartSpan(
    name: String,
    kind: SpanKind,
    parent_context: Option(SpanContext),
    reply_to: Subject(Result(Span, String)),
  )
  EndSpan(span_id: String, status: SpanStatus)
  AddSpanEvent(
    span_id: String,
    name: String,
    attributes: List(#(String, String)),
  )
  SetSpanAttributes(span_id: String, attributes: List(#(String, String)))
  ForceFlush(reply_to: Subject(Nil))
  Shutdown(reply_to: Subject(Nil))
}

pub type TracerState {
  TracerState(
    config: TracerConfig,
    active_spans: List(#(String, Span)),
    pending_exports: List(Span),
  )
}

pub type Tracer =
  Subject(TelemetryCommand)

@external(erlang, "rand", "uniform")
fn random_uniform(n: Int) -> Int

fn generate_id_chars(count: Int, acc: String) -> String {
  case count {
    0 -> acc
    _ -> {
      let idx = random_uniform(16)
      let char = case idx {
        0 -> "0"
        1 -> "1"
        2 -> "2"
        3 -> "3"
        4 -> "4"
        5 -> "5"
        6 -> "6"
        7 -> "7"
        8 -> "8"
        9 -> "9"
        10 -> "a"
        11 -> "b"
        12 -> "c"
        13 -> "d"
        14 -> "e"
        15 -> "f"
        _ -> "0"
      }
      generate_id_chars(count - 1, acc <> char)
    }
  }
}

fn generate_trace_id() -> String {
  generate_id_chars(32, "")
}

fn generate_span_id() -> String {
  generate_id_chars(16, "")
}

pub fn create_span_context() -> SpanContext {
  SpanContext(
    trace_id: generate_trace_id(),
    span_id: generate_span_id(),
    trace_flags: 1,
    trace_state: "",
  )
}
