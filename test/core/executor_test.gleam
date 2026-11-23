//// Tests for the Executor module.
////
//// Verifies the agent execution loop: LLM calls, tool dispatch, recursion.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/core/executor
import supernova/llm/provider
import supernova/llm/stream
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

pub fn builtin_tools_include_web_fetch_test() {
  executor.builtin_tools()
  |> list.any(fn(tool) { tool.name == "web_fetch" })
  |> should.equal(True)
}

pub fn builtin_tools_include_git_inspect_test() {
  executor.builtin_tools()
  |> list.any(fn(tool) { tool.name == "git_inspect" })
  |> should.equal(True)
}

pub fn builtin_tools_include_file_system_test() {
  executor.builtin_tools()
  |> list.any(fn(tool) { tool.name == "file_system" })
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

pub fn invalid_web_fetch_tool_arguments_returns_error_message_test() {
  let calls = [
    provider.ToolCall(id: "c1", name: "web_fetch", arguments: "{\"uri\":\"x\"}"),
  ]
  let tools = [provider.new_tool("web_fetch", "Web fetch", [])]

  let messages = executor.execute_tool_calls_for_test(calls, tools)

  case messages {
    [msg] ->
      msg.content
      |> should.equal("ERROR: Invalid arguments for web_fetch")
    _ -> should.fail()
  }
}

pub fn invalid_git_inspect_tool_arguments_returns_error_message_test() {
  let calls = [
    provider.ToolCall(
      id: "c1",
      name: "git_inspect",
      arguments: "{\"wrong\":\"field\"}",
    ),
  ]
  let tools = [provider.new_tool("git_inspect", "Git inspect", [])]

  let messages = executor.execute_tool_calls_for_test(calls, tools)

  case messages {
    [msg] ->
      msg.content
      |> should.equal("ERROR: Invalid arguments for git_inspect")
    _ -> should.fail()
  }
}

pub fn git_inspect_alias_invalid_action_returns_error_message_test() {
  let calls = [
    provider.ToolCall(
      id: "c1",
      name: "git_inspect",
      arguments: "{\"command\":\"fetch\"}",
    ),
  ]
  let tools = [provider.new_tool("git_inspect", "Git inspect", [])]

  let messages = executor.execute_tool_calls_for_test(calls, tools)

  case messages {
    [msg] ->
      msg.content
      |> should.equal(
        "ERROR: git_inspect action must be status, log, branch, diff, or show",
      )
    _ -> should.fail()
  }
}

pub fn invalid_file_system_tool_arguments_returns_error_message_test() {
  let calls = [
    provider.ToolCall(
      id: "c1",
      name: "file_system",
      arguments: "{\"path\":\".\"}",
    ),
  ]
  let tools = [provider.new_tool("file_system", "File system", [])]

  let messages = executor.execute_tool_calls_for_test(calls, tools)

  case messages {
    [msg] ->
      msg.content
      |> should.equal("ERROR: Invalid arguments for file_system")
    _ -> should.fail()
  }
}

pub fn declared_but_unwired_tool_returns_executor_error_message_test() {
  let calls = [
    provider.ToolCall(id: "c1", name: "custom_tool", arguments: "{}"),
  ]
  let tools = [provider.new_tool("custom_tool", "Custom", [])]

  let messages = executor.execute_tool_calls_for_test(calls, tools)

  case messages {
    [msg] ->
      msg.content
      |> should.equal("ERROR: Tool 'custom_tool' is not wired in executor")
    _ -> should.fail()
  }
}

pub fn run_stream_mock_default_chunks_test() {
  let config =
    provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock-model",
    )
  let stream_subject =
    executor.run_stream_mock([provider.user_message("hello")], config, [])

  let assert Ok(stream.TextChunk(content: "Mock ")) =
    process.receive(stream_subject, within: 100)
  let assert Ok(stream.TextChunk(content: "streaming ")) =
    process.receive(stream_subject, within: 100)
  let assert Ok(stream.TextChunk(content: "response")) =
    process.receive(stream_subject, within: 100)
  let assert Ok(stream.Done) = process.receive(stream_subject, within: 100)
}

pub fn run_stream_mock_echo_model_chunks_test() {
  let config =
    provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock-model",
    )
  let stream_subject =
    executor.run_stream_mock(
      [provider.user_message("please [echo-model]")],
      config,
      [],
    )

  let assert Ok(stream.TextChunk(content)) =
    process.receive(stream_subject, within: 100)
  content |> should.equal("Mock response via mock-model")
  let assert Ok(stream.Done) = process.receive(stream_subject, within: 100)
}

pub fn run_stream_mock_stream_error_marker_test() {
  let config =
    provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock-model",
    )
  let stream_subject =
    executor.run_stream_mock(
      [provider.user_message("trigger [stream-error] now")],
      config,
      [],
    )

  let assert Ok(stream.StreamError(reason: reason)) =
    process.receive(stream_subject, within: 100)
  reason |> should.equal("simulated mock stream error")
}

pub fn run_stream_mock_stream_timeout_marker_emits_no_chunks_test() {
  let config =
    provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock-model",
    )
  let stream_subject =
    executor.run_stream_mock(
      [provider.user_message("simulate [stream-timeout]")],
      config,
      [],
    )

  case process.receive(stream_subject, within: 50) {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn tool_definitions_and_calls_are_counted_in_estimates_test() {
  let messages = [provider.user_message("hello")]
  let response =
    provider.ChatResponse(
      role: "assistant",
      content: "",
      tool_calls: Some([
        provider.ToolCall(
          id: "call-1",
          name: "file_system",
          arguments: "{\"path\":\"src/main.gleam\"}",
        ),
      ]),
      reasoning_content: None,
    )
  let tools = [
    provider.new_tool("file_system", "Read and write workspace files", [
      provider.string_param("path", "File path", True),
    ]),
  ]

  let #(empty_prompt, _) =
    executor.estimate_usage_for_test(messages, response, [])
  let #(tool_prompt, tool_output) =
    executor.estimate_usage_for_test(messages, response, tools)
  let text_response =
    provider.ChatResponse(
      role: "assistant",
      content: "",
      tool_calls: None,
      reasoning_content: None,
    )
  let #(_, text_output) =
    executor.estimate_usage_for_test(messages, text_response, [])

  { tool_prompt > empty_prompt } |> should.equal(True)
  { tool_output > text_output } |> should.equal(True)
}

/// The calls of one round run at the same time: two that take 400 ms each
/// finish together in about 400 ms, not 800; the results keep the calls'
/// order; a call that crashes gives an error text and the others still
/// answer.
pub fn the_calls_of_a_round_run_concurrently_test() {
  let tool = fn(name) {
    provider.new_tool(name: name, description: "test", parameters: [])
  }
  let invoke = fn(name: String, _arguments: String) {
    case name {
      "boom" -> panic as "tool exploded"
      _ -> {
        process.sleep(400)
        Ok("done " <> name)
      }
    }
  }
  let context =
    executor.RunContext(
      ..executor.empty_run_context(),
      invoke_tool: Some(invoke),
    )
  let calls = [
    provider.ToolCall(id: "c1", name: "slow_a", arguments: "{}"),
    provider.ToolCall(id: "c2", name: "boom", arguments: "{}"),
    provider.ToolCall(id: "c3", name: "slow_b", arguments: "{}"),
  ]
  let started = monotonic_ms()
  let results =
    executor.execute_tool_calls_with_context_for_test(
      calls,
      [tool("slow_a"), tool("boom"), tool("slow_b")],
      context,
    )
  let elapsed = monotonic_ms() - started
  { elapsed < 750 } |> should.be_true()
  results
  |> list.map(fn(message) {
    #(message.tool_call_id, string.starts_with(message.content, "ERROR:"))
  })
  |> should.equal([
    #(Some("c1"), False),
    #(Some("c2"), True),
    #(Some("c3"), False),
  ])
  let assert [first, ..] = results
  first.content |> should.equal("done slow_a")
}

@external(erlang, "supernova_stress_ffi", "mono_ms")
fn monotonic_ms() -> Int
