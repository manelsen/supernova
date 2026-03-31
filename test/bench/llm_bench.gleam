//// LLM Latency Benchmarks.
////
//// Measures round-trip latency for LLM calls with mock and real providers.
////
//// Run with: gleam test

import gleam/option.{None, Some}
import gleeunit/should
import supernova/llm/client
import supernova/llm/provider

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn timestamp() -> Int

fn ms_since(ts: Int) -> Int {
  timestamp() - ts
}

pub fn mock_llm_latency_bench() {
  let config =
    provider.ProviderConfig(
      name: "mock",
      default_model: "mock",
      api_key: Some("test"),
      base_url: None,
    )
  let messages = [provider.user_message("Hello, respond briefly.")]

  let start = timestamp()
  let result = client.chat(messages, config, [])
  let elapsed = ms_since(start)

  result |> should.be_ok()
  elapsed < 50
}

pub fn mock_llm_with_tools_latency_bench() {
  let config =
    provider.ProviderConfig(
      name: "mock",
      default_model: "mock",
      api_key: Some("test"),
      base_url: None,
    )
  let messages = [provider.user_message("Use the shell to list files.")]
  let tools = [
    provider.new_tool(
      name: "safe_shell",
      description: "Run a shell command",
      parameters: [
        provider.ToolParam(
          param_type: "string",
          name: "command",
          description: "The command to run",
          required: True,
        ),
      ],
    ),
  ]

  let start = timestamp()
  let result = client.chat(messages, config, tools)
  let elapsed = ms_since(start)

  result |> should.be_ok()
  elapsed < 50
}

pub fn provider_config_creation_bench() {
  let start = timestamp()
  let _config =
    provider.ProviderConfig(
      name: "openai",
      default_model: "gpt-4",
      api_key: Some("sk-test"),
      base_url: None,
    )
  let elapsed = ms_since(start)

  elapsed < 1
}

pub fn message_list_creation_bench() {
  let start = timestamp()
  let _messages = [
    provider.system_message("You are a helpful assistant."),
    provider.user_message("Hello!"),
  ]
  let elapsed = ms_since(start)

  elapsed < 1
}
