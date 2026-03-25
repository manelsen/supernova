//// Tests for the LLM Streaming module.
////
//// Verifies SSE parsing for OpenAI and Anthropic, chunk handling,
//// timeout behavior, and error mid-stream scenarios.

import gleeunit/should
import supernova/llm/provider
import supernova/llm/stream

// ============================================================================
// OpenAI SSE Parsing
// ============================================================================

pub fn parse_openai_text_chunk_test() {
  let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"
  let chunks = stream.parse_openai_sse(sse)

  chunks
  |> should.equal([stream.TextChunk(content: "Hello")])
}

pub fn parse_openai_multiple_chunks_test() {
  let sse =
    "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n"
  let chunks = stream.parse_openai_sse(sse)

  chunks
  |> should.equal([
    stream.TextChunk(content: "Hello"),
    stream.TextChunk(content: " world"),
  ])
}

pub fn parse_openai_done_test() {
  let sse = "data: [DONE]\n\n"
  let chunks = stream.parse_openai_sse(sse)

  chunks
  |> should.equal([stream.Done])
}

pub fn parse_openai_empty_content_test() {
  let sse = "data: {\"choices\":[{\"delta\":{}}]}\n\n"
  let chunks = stream.parse_openai_sse(sse)

  chunks
  |> should.equal([stream.TextChunk(content: "")])
}

pub fn parse_openai_tool_call_chunk_test() {
  let sse =
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_123\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Lisbon\\\"}\"}}]}}]}\n\n"
  let chunks = stream.parse_openai_sse(sse)

  case chunks {
    [stream.ToolCallChunk(id, name, args, index)] -> {
      id |> should.equal("call_123")
      name |> should.equal("get_weather")
      args |> should.equal("{\"city\":\"Lisbon\"}")
      index |> should.equal(0)
    }
    _ -> should.fail()
  }
}

pub fn parse_openai_comment_lines_skipped_test() {
  let sse =
    ": this is a comment\ndata: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n"
  let chunks = stream.parse_openai_sse(sse)

  chunks
  |> should.equal([stream.TextChunk(content: "Hi")])
}

pub fn parse_openai_empty_lines_skipped_test() {
  let sse = "\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"Test\"}}]}\n\n"
  let chunks = stream.parse_openai_sse(sse)

  chunks
  |> should.equal([stream.TextChunk(content: "Test")])
}

// ============================================================================
// Anthropic Event Parsing
// ============================================================================

pub fn parse_anthropic_text_delta_test() {
  let event =
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\n"
  let chunks = stream.parse_anthropic_events(event)

  chunks
  |> should.equal([stream.TextChunk(content: "Hello")])
}

pub fn parse_anthropic_message_stop_test() {
  let event = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
  let chunks = stream.parse_anthropic_events(event)

  chunks
  |> should.equal([stream.Done])
}

pub fn parse_anthropic_error_test() {
  let event =
    "event: error\ndata: {\"type\":\"error\",\"message\":\"Rate limit exceeded\"}\n\n"
  let chunks = stream.parse_anthropic_events(event)

  case chunks {
    [stream.StreamError(reason)] -> {
      reason |> should.equal("error: Rate limit exceeded")
    }
    _ -> should.fail()
  }
}

pub fn parse_anthropic_tool_delta_test() {
  let event =
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\":\\\"Lisbon\\\"}\"}}\n\n"
  let chunks = stream.parse_anthropic_events(event)

  case chunks {
    [stream.ToolCallChunk(_, _, args_delta, _)] -> {
      args_delta |> should.equal("{\"city\":\"Lisbon\"}")
    }
    _ -> should.fail()
  }
}

pub fn parse_anthropic_message_start_test() {
  let event =
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_123\",\"type\":\"message\",\"role\":\"assistant\"}}\n\n"
  let chunks = stream.parse_anthropic_events(event)

  chunks
  |> should.equal([stream.TextChunk(content: "")])
}

pub fn parse_anthropic_content_block_start_test() {
  let event =
    "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}\n\n"
  let chunks = stream.parse_anthropic_events(event)

  chunks
  |> should.equal([stream.TextChunk(content: "")])
}

pub fn parse_anthropic_multiple_events_test() {
  let events =
    "event: message_start\ndata: {\"type\":\"message_start\"}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
  let chunks = stream.parse_anthropic_events(events)

  chunks
  |> should.equal([
    stream.TextChunk(content: ""),
    stream.TextChunk(content: "Hi"),
    stream.Done,
  ])
}

// ============================================================================
// StreamChunk Type Tests
// ============================================================================

pub fn text_chunk_equality_test() {
  let chunk1 = stream.TextChunk(content: "Hello")
  let chunk2 = stream.TextChunk(content: "Hello")

  chunk1
  |> should.equal(chunk2)
}

pub fn done_chunk_test() {
  let chunk = stream.Done

  chunk
  |> should.equal(stream.Done)
}

pub fn stream_error_test() {
  let chunk = stream.StreamError(reason: "timeout")

  chunk.reason
  |> should.equal("timeout")
}

// ============================================================================
// Request Body Building
// ============================================================================

pub fn openai_stream_body_test() {
  let messages = [provider.user_message("Hello")]
  let body = stream.openai_stream_body(messages, "gpt-4o", [])

  body
  |> should.equal(
    "{\"model\":\"gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"stream\":true}",
  )
}

pub fn openai_stream_body_with_tools_test() {
  let messages = [provider.user_message("What's the weather?")]
  let tools = [
    provider.new_tool(
      name: "get_weather",
      description: "Get weather",
      parameters: [provider.string_param("city", "City name", True)],
    ),
  ]
  let body = stream.openai_stream_body(messages, "gpt-4o", tools)

  // Verify stream flag is set
  body
  |> should.equal(
    "{\"model\":\"gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":\"What's the weather?\"}],\"stream\":true,\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"Get weather\",\"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"description\":\"City name\"}},\"required\":[\"city\"]}}}]}",
  )
}

pub fn anthropic_stream_body_test() {
  let messages = [provider.user_message("Hello")]
  let body =
    stream.anthropic_stream_body(messages, "claude-3-opus-20240229", [])

  body
  |> should.equal(
    "{\"model\":\"claude-3-opus-20240229\",\"max_tokens\":4096,\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"stream\":true}",
  )
}

pub fn anthropic_stream_body_with_system_test() {
  let messages = [
    provider.system_message("You are helpful."),
    provider.user_message("Hello"),
  ]
  let body =
    stream.anthropic_stream_body(messages, "claude-3-opus-20240229", [])

  body
  |> should.equal(
    "{\"model\":\"claude-3-opus-20240229\",\"max_tokens\":4096,\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"stream\":true,\"system\":\"You are helpful.\"}",
  )
}

// ============================================================================
// Edge Cases
// ============================================================================

pub fn parse_empty_string_test() {
  let chunks = stream.parse_openai_sse("")

  chunks
  |> should.equal([])
}

pub fn parse_anthropic_empty_string_test() {
  let chunks = stream.parse_anthropic_events("")

  chunks
  |> should.equal([])
}

pub fn parse_openai_invalid_json_test() {
  let sse = "data: not valid json\n\n"
  let chunks = stream.parse_openai_sse(sse)

  // Invalid JSON should be skipped
  chunks
  |> should.equal([])
}

pub fn parse_anthropic_unknown_event_test() {
  let event = "event: unknown_event\ndata: {\"type\":\"unknown\"}\n\n"
  let chunks = stream.parse_anthropic_events(event)

  // Unknown events should be skipped
  chunks
  |> should.equal([])
}

pub fn parse_openai_chunk_directly_test() {
  let result =
    stream.parse_openai_chunk(
      "{\"choices\":[{\"delta\":{\"content\":\"Test\"}}]}",
    )

  result
  |> should.equal(Ok(stream.TextChunk(content: "Test")))
}

pub fn parse_openai_chunk_invalid_test() {
  let result = stream.parse_openai_chunk("invalid json")

  result
  |> should.equal(Error(Nil))
}
