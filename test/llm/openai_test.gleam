//// Tests for the OpenAI provider.

import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/llm/provider
import supernova/llm/providers/openai

pub fn build_request_body_test() {
  let messages = [provider.user_message("Hello")]
  let body = openai.build_request_body(messages, "gpt-4o", [])

  string.contains(body, "\"model\":\"gpt-4o\"")
  |> should.equal(True)

  string.contains(body, "\"role\":\"user\"")
  |> should.equal(True)

  string.contains(body, "\"content\":\"Hello\"")
  |> should.equal(True)
}

pub fn build_request_body_with_tools_test() {
  let messages = [provider.user_message("What's the weather?")]
  let tools = [
    provider.new_tool(
      name: "get_weather",
      description: "Get weather",
      parameters: [provider.string_param("city", "City name", True)],
    ),
  ]

  let body = openai.build_request_body(messages, "gpt-4o", tools)

  string.contains(body, "\"tools\"")
  |> should.equal(True)

  string.contains(body, "\"get_weather\"")
  |> should.equal(True)
}

pub fn parse_response_test() {
  let json =
    "{\"id\":\"chatcmpl-123\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Hi there!\"}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5}}"

  let result = openai.parse_response(json)

  case result {
    Ok(response) -> {
      response.role
      |> should.equal("assistant")

      response.content
      |> should.equal("Hi there!")
    }
    Error(_) -> should.fail()
  }
}

pub fn parse_response_with_tool_calls_test() {
  let json =
    "{\"id\":\"chatcmpl-456\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Lisbon\\\"}\"}}]}}]}"

  let result = openai.parse_response(json)

  case result {
    Ok(response) -> {
      response.role
      |> should.equal("assistant")

      case response.tool_calls {
        Some(calls) -> {
          calls
          |> should.equal([
            provider.ToolCall(
              id: "call_1",
              name: "get_weather",
              arguments: "{\"city\":\"Lisbon\"}",
            ),
          ])
        }
        None -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn parse_error_response_test() {
  let json =
    "{\"error\":{\"message\":\"Invalid API key\",\"type\":\"authentication_error\"}}"

  let result = openai.parse_response(json)

  result
  |> should.be_error
}
