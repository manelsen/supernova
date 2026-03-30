//// Tests for the Executor module.
////
//// Verifies the agent execution loop: LLM calls, tool dispatch, recursion.

import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/core/executor
import supernova/llm/provider
import supernova/tools/browser
import supernova/tools/canvas as canvas_tool
import supernova/tools/gateway as gateway_tool
import supernova/tools/github as github_tool
import supernova/tools/process as process_tool
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

pub fn builtin_tools_include_browser_test() {
  executor.builtin_tools()
  |> list.any(fn(tool) { tool.name == "browser" })
  |> should.equal(True)
}

pub fn builtin_tools_include_canvas_test() {
  executor.builtin_tools()
  |> list.any(fn(tool) { tool.name == "canvas" })
  |> should.equal(True)
}

pub fn builtin_tools_include_gateway_test() {
  executor.builtin_tools()
  |> list.any(fn(tool) { tool.name == "gateway" })
  |> should.equal(True)
}

pub fn builtin_tools_include_process_test() {
  executor.builtin_tools()
  |> list.any(fn(tool) { tool.name == "process" })
  |> should.equal(True)
}

pub fn builtin_tools_include_github_test() {
  executor.builtin_tools()
  |> list.any(fn(tool) { tool.name == "github" })
  |> should.equal(True)
}

pub fn invalid_browser_tool_arguments_returns_error_message_test() {
  let calls = [
    provider.ToolCall(
      id: "c1",
      name: "browser",
      arguments: "{\"url\":\"https://example.com\"}",
    ),
  ]
  let tools = [browser.tool()]

  let messages = executor.execute_tool_calls_for_test(calls, tools)

  case messages {
    [msg] ->
      string.starts_with(msg.content, "ERROR: Invalid arguments for browser")
      |> should.equal(True)
    _ -> should.fail()
  }
}

pub fn invalid_canvas_tool_arguments_returns_error_message_test() {
  let calls = [
    provider.ToolCall(
      id: "c1",
      name: "canvas",
      arguments: "{\"title\":\"Plan\"}",
    ),
  ]
  let tools = [canvas_tool.tool()]

  let messages = executor.execute_tool_calls_for_test(calls, tools)

  case messages {
    [msg] ->
      string.starts_with(msg.content, "ERROR: Invalid arguments for canvas")
      |> should.equal(True)
    _ -> should.fail()
  }
}

pub fn invalid_gateway_tool_arguments_returns_error_message_test() {
  let calls = [
    provider.ToolCall(
      id: "c1",
      name: "gateway",
      arguments: "{\"agent_id\":\"ghost\"}",
    ),
  ]
  let tools = [gateway_tool.tool()]

  let messages = executor.execute_tool_calls_for_test(calls, tools)

  case messages {
    [msg] ->
      string.starts_with(msg.content, "ERROR: Invalid arguments for gateway")
      |> should.equal(True)
    _ -> should.fail()
  }
}

pub fn invalid_process_tool_arguments_returns_error_message_test() {
  let calls = [
    provider.ToolCall(id: "c1", name: "process", arguments: "{\"pid\":123}"),
  ]
  let tools = [process_tool.tool()]

  let messages = executor.execute_tool_calls_for_test(calls, tools)

  case messages {
    [msg] ->
      string.starts_with(msg.content, "ERROR: Invalid arguments for process")
      |> should.equal(True)
    _ -> should.fail()
  }
}

pub fn invalid_github_tool_arguments_returns_error_message_test() {
  let calls = [
    provider.ToolCall(
      id: "c1",
      name: "github",
      arguments: "{\"language\":\"Gleam\"}",
    ),
  ]
  let tools = [github_tool.tool()]

  let messages = executor.execute_tool_calls_for_test(calls, tools)

  case messages {
    [msg] ->
      string.starts_with(msg.content, "ERROR: Invalid arguments for github")
      |> should.equal(True)
    _ -> should.fail()
  }
}
