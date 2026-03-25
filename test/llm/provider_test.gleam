//// Tests for LLM provider types and client.
////
//// Verifies message/response types, tool definitions, and client dispatch.

import gleam/option.{None, Some}
import gleeunit/should
import supernova/llm/client
import supernova/llm/provider

// ============================================================================
// Provider Types
// ============================================================================

pub fn user_message_test() {
  let msg = provider.user_message("Hello!")

  msg.role
  |> should.equal("user")

  msg.content
  |> should.equal("Hello!")
}

pub fn system_message_test() {
  let msg = provider.system_message("You are a helpful assistant.")

  msg.role
  |> should.equal("system")

  msg.content
  |> should.equal("You are a helpful assistant.")
}

pub fn assistant_message_test() {
  let msg = provider.assistant_message("Hi there!")

  msg.role
  |> should.equal("assistant")

  msg.content
  |> should.equal("Hi there!")
}

pub fn assistant_message_with_tool_calls_test() {
  let tool_call =
    provider.ToolCall(
      id: "call_123",
      name: "get_weather",
      arguments: "{\"city\": \"Lisbon\"}",
    )

  let msg = provider.assistant_message_with_tools("Let me check.", [tool_call])

  msg.role
  |> should.equal("assistant")

  msg.content
  |> should.equal("Let me check.")

  case msg.tool_calls {
    Some(calls) -> {
      calls
      |> should.equal([tool_call])
    }
    None -> should.fail()
  }
}

pub fn tool_result_message_test() {
  let msg = provider.tool_result_message("call_123", "Sunny, 22°C")

  msg.role
  |> should.equal("tool")

  msg.content
  |> should.equal("Sunny, 22°C")

  msg.tool_call_id
  |> should.equal(Some("call_123"))
}

// ============================================================================
// Tool Definitions
// ============================================================================

pub fn tool_definition_test() {
  let tool =
    provider.new_tool(
      name: "get_weather",
      description: "Get weather for a city",
      parameters: [
        provider.string_param("city", "City name", True),
      ],
    )

  tool.name
  |> should.equal("get_weather")

  tool.description
  |> should.equal("Get weather for a city")

  tool.parameters
  |> should.equal([
    provider.string_param("city", "City name", True),
  ])
}

// ============================================================================
// Client
// ============================================================================

pub fn client_with_mock_provider_test() {
  let config =
    provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock-model",
    )

  let messages = [provider.user_message("Hello")]

  let result = client.chat(messages, config, [])

  case result {
    Ok(response) -> {
      response.role
      |> should.equal("assistant")
    }
    Error(_) -> should.fail()
  }
}

pub fn client_openai_without_key_uses_real_provider_test() {
  let config =
    provider.ProviderConfig(
      name: "openai",
      api_key: None,
      base_url: None,
      default_model: "gpt-4o-mini",
    )

  let messages = [provider.user_message("Hello")]
  let result = client.chat(messages, config, [])

  result
  |> should.equal(
    Error(provider.ConfigError(reason: "No API key configured for OpenAI")),
  )
}

pub fn client_anthropic_without_key_uses_real_provider_test() {
  let config =
    provider.ProviderConfig(
      name: "anthropic",
      api_key: None,
      base_url: None,
      default_model: "claude-haiku-4-5",
    )

  let messages = [provider.user_message("Hello")]
  let result = client.chat(messages, config, [])

  result
  |> should.equal(
    Error(provider.ConfigError(reason: "No API key configured for Anthropic")),
  )
}
