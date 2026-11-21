import gleam/string
import gleeunit/should
import supernova/llm/providers/openai_compatible

// A 422 from Mistral echoes the offending input; the summary keeps the
// field path and the reason, never the input itself.
pub fn validation_error_drops_input_test() {
  let body =
    "{\"detail\":[{\"type\":\"extra_forbidden\",\"loc\":[\"body\",\"messages\",1,\"assistant\",\"reasoning_content\"],\"msg\":\"Extra inputs are not permitted\",\"input\":\"segredo da conversa\"}]}"
  let summary = openai_compatible.error_summary(body)
  summary
  |> should.equal(
    "extra_forbidden at body.messages.1.assistant.reasoning_content: Extra inputs are not permitted",
  )
  string.contains(summary, "segredo") |> should.be_false
}

pub fn mistral_error_object_test() {
  "{\"object\":\"error\",\"message\":\"Service tier capacity exceeded\",\"type\":\"service_tier_capacity_exceeded\",\"code\":\"3505\"}"
  |> openai_compatible.error_summary
  |> should.equal(
    "service_tier_capacity_exceeded: Service tier capacity exceeded",
  )
}

pub fn openai_error_object_test() {
  "{\"error\":{\"message\":\"Incorrect API key\",\"type\":\"invalid_request_error\"}}"
  |> openai_compatible.error_summary
  |> should.equal("invalid_request_error: Incorrect API key")
}

pub fn unknown_body_reports_only_size_test() {
  "<html>conteúdo qualquer</html>"
  |> openai_compatible.error_summary
  |> should.equal("unparsed body, 31 bytes")
}
