//// Tests for the Executor module.
////
//// Verifies the agent execution loop: LLM calls, tool dispatch, recursion.

import gleam/option.{None}
import gleeunit/should
import supernova/core/executor
import supernova/llm/provider
import supernova/tools/safe_shell

pub fn execute_text_response_test() {
  let messages = [provider.user_message("Hello")]
  let config =
    provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock-model",
    )

  let result = executor.run(messages, config, [])

  case result {
    Ok(response) -> {
      response.content
      |> should.equal("Mock response")
    }
    Error(_) -> should.fail()
  }
}

pub fn execute_with_max_depth_test() {
  let messages = [provider.user_message("Test")]
  let config =
    provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock-model",
    )

  // Should complete without infinite loop
  let result = executor.run(messages, config, [])
  result
  |> should.be_ok
}

pub fn executor_result_has_content_test() {
  let messages = [provider.user_message("Hi")]
  let config =
    provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock",
    )

  let assert Ok(result) = executor.run(messages, config, [])

  result.role
  |> should.equal("assistant")
}

pub fn executes_builtin_tool_calls_test() {
  let messages = [provider.user_message("Run a safe command")]
  let config =
    provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock-model",
    )
  let tools = [safe_shell.tool()]

  let result = executor.run(messages, config, tools)
  result
  |> should.be_ok
}

pub fn undeclared_tool_call_returns_error_message_test() {
  let calls = [
    provider.ToolCall(
      id: "c1",
      name: "safe_shell",
      arguments: "{\"command\":\"pwd\"}",
    ),
  ]

  let messages = executor.execute_tool_calls_for_test(calls, [])

  case messages {
    [msg] -> {
      msg.content
      |> should.equal("ERROR: Tool 'safe_shell' is not declared for this turn")
    }
    _ -> should.fail()
  }
}

pub fn invalid_tool_arguments_returns_error_message_test() {
  let calls = [
    provider.ToolCall(
      id: "c1",
      name: "safe_shell",
      arguments: "{\"bad\":\"value\"}",
    ),
  ]
  let tools = [safe_shell.tool()]

  let messages = executor.execute_tool_calls_for_test(calls, tools)

  case messages {
    [msg] -> {
      msg.content
      |> should.equal("ERROR: Invalid arguments for safe_shell")
    }
    _ -> should.fail()
  }
}
