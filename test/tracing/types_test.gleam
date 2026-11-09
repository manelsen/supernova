import gleam/string
import gleeunit
import gleeunit/should
import supernova/tracing/types as tracing

pub fn main() {
  gleeunit.main()
}

pub fn create_span_context_generates_trace_and_span_ids_test() {
  let span_context = tracing.create_span_context()

  string.length(span_context.trace_id) |> should.equal(32)
  string.length(span_context.span_id) |> should.equal(16)
  span_context.trace_flags |> should.equal(1)
  span_context.trace_state |> should.equal("")
}
