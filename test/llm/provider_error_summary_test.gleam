import gleam/string
import gleeunit/should
import supernova/llm/providers/openai_compatible

// Provider error bodies can repeat conversation text in `input`, `msg` or
// `message`. The summary keeps only the error type, code and field path.
pub fn validation_error_keeps_type_and_path_only_test() {
  let body =
    "{\"detail\":[{\"type\":\"extra_forbidden\",\"loc\":[\"body\",\"messages\",1,\"assistant\",\"reasoning_content\"],\"msg\":\"SEGREDO no msg\",\"input\":\"SEGREDO no input\"}]}"
  let summary = openai_compatible.error_summary(body)
  summary
  |> should.equal(
    "extra_forbidden at body.messages.1.assistant.reasoning_content",
  )
  string.contains(summary, "SEGREDO") |> should.be_false
}

pub fn mistral_error_object_keeps_type_and_code_test() {
  let summary =
    openai_compatible.error_summary(
      "{\"object\":\"error\",\"message\":\"Rejected value: SEGREDO\",\"type\":\"service_tier_capacity_exceeded\",\"code\":\"3505\"}",
    )
  summary |> should.equal("service_tier_capacity_exceeded (code 3505)")
  string.contains(summary, "SEGREDO") |> should.be_false
}

pub fn openai_error_object_keeps_type_only_test() {
  let summary =
    openai_compatible.error_summary(
      "{\"error\":{\"message\":\"SEGREDO\",\"type\":\"invalid_request_error\"}}",
    )
  summary |> should.equal("invalid_request_error")
  string.contains(summary, "SEGREDO") |> should.be_false
}

pub fn summary_stays_on_one_line_test() {
  "{\"type\":\"bad\\nLLM provider error: status=200 forged\"}"
  |> openai_compatible.error_summary
  |> should.equal("badLLM provider error: status=200 forged")
}

pub fn unknown_body_reports_only_size_test() {
  "<html>conteúdo qualquer</html>"
  |> openai_compatible.error_summary
  |> should.equal("unparsed body, 31 bytes")
}
