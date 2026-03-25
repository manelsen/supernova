//// LLM Client — dispatcher for LLM provider calls.
////
//// Routes chat completion requests to the appropriate provider based on config.
//// Includes a mock provider for testing.
////
//// ## Usage
////
//// ```gleam
//// let config = provider.ProviderConfig(name: "openai", ...)
//// let result = client.chat(messages, config, [])
//// ```

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import supernova/llm/provider
import supernova/llm/providers/anthropic
import supernova/llm/providers/minimax
import supernova/llm/providers/openai
import supernova/llm/providers/opencode_zen
import supernova/llm/providers/openrouter
import supernova/llm/providers/zhipu

// ============================================================================
// Public API
// ============================================================================

/// Send a chat completion request.
///
/// Dispatches to the provider specified in config.
/// Returns a ChatResponse on success or LLMError on failure.
pub fn chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  case config.name {
    "mock" -> mock_chat(messages, config, tools)
    "openai" -> openai.chat(messages, config, tools)
    "anthropic" -> anthropic.chat(messages, config, tools)
    "opencode_zen" -> opencode_zen.chat(messages, config, tools)
    "openrouter" -> openrouter.chat(messages, config, tools)
    "zhipu" -> zhipu.chat(messages, config, tools)
    "zhipu_coding" -> zhipu.chat_coding(messages, config, tools)
    "minimax" -> minimax.chat(messages, config, tools)
    _ -> Error(provider.ProviderNotFound(name: config.name))
  }
}

// ============================================================================
// Mock Provider (for testing)
// ============================================================================

/// Mock chat completion — returns a canned response.
fn mock_chat(
  messages: List(provider.ChatMessage),
  _config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  let has_tool_result =
    list.any(messages, fn(message) { message.role == "tool" })
  let has_tool_error =
    list.any(messages, fn(message) {
      message.role == "tool" && string.starts_with(message.content, "ERROR:")
    })

  case tools, has_tool_result {
    [], _ ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: "Mock response",
        tool_calls: None,
        reasoning_content: None,
      ))
    _, True ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: case has_tool_error {
          True -> "Mock tool error"
          False -> "Mock response"
        },
        tool_calls: None,
        reasoning_content: None,
      ))
    [first_tool, ..], False ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: "",
        tool_calls: Some([
          provider.ToolCall(
            id: "mock_tool_call_1",
            name: first_tool.name,
            arguments: mock_arguments_for_tool(first_tool.name),
          ),
        ]),
        reasoning_content: None,
      ))
  }
}

fn mock_arguments_for_tool(tool_name: String) -> String {
  case tool_name {
    "safe_shell" -> "{\"command\":\"pwd\"}"
    "web_fetch" -> "{\"url\":\"https://example.com\"}"
    "git_inspect" -> "{\"action\":\"status\"}"
    "file_system" -> "{\"action\":\"list\",\"path\":\".\"}"
    _ -> "{}"
  }
}
