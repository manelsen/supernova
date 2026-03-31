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
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/llm/provider
import supernova/llm/providers/anthropic
import supernova/llm/providers/minimax
import supernova/llm/providers/ollama
import supernova/llm/providers/openai
import supernova/llm/providers/openai_compatible
import supernova/llm/providers/opencode_zen
import supernova/llm/providers/openrouter
import supernova/llm/providers/zhipu

type MockToolMode {
  MockToolDefault
  MockToolLoopSuccess
  MockToolLoopError
}

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
    "ollama" -> ollama.chat(messages, config, tools)
    "zai" ->
      openai_compatible.chat(
        messages,
        config,
        tools,
        base_url: "https://api.z.ai/api/paas/v4/chat/completions",
        extra_headers: [],
      )
    "zai_coding" ->
      openai_compatible.chat(
        messages,
        config,
        tools,
        base_url: "https://api.z.ai/api/paas/v4/chat/completions",
        extra_headers: [],
      )
    _ -> Error(provider.ProviderNotFound(name: config.name))
  }
}

// ============================================================================
// Mock Provider (for testing)
// ============================================================================

/// Mock chat completion — returns a canned response.
fn mock_chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  case special_mock_response(messages, config) {
    Some(content) ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: content,
        tool_calls: None,
        reasoning_content: None,
      ))
    None -> mock_chat_default(messages, config, tools)
  }
}

fn mock_chat_default(
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
  let tool_mode = mock_tool_mode(messages)

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
          False ->
            case tool_mode {
              MockToolLoopSuccess -> "Mock tool success"
              _ -> "Mock response"
            }
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
            arguments: mock_arguments_for_tool(first_tool.name, tool_mode),
          ),
        ]),
        reasoning_content: None,
      ))
  }
}

fn special_mock_response(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
) -> Option(String) {
  case latest_user_content(messages) {
    Some(content) ->
      case string.contains(content, "[stream-error]") {
        True -> Some("Mock fallback after stream error")
        False ->
          case string.contains(content, "[stream-timeout]") {
            True -> Some("Mock fallback after stream timeout")
            False ->
              case string.contains(content, "[echo-model]") {
                True -> Some("Mock response via " <> config.default_model)
                False -> None
              }
          }
      }
    None -> None
  }
}

fn mock_tool_mode(messages: List(provider.ChatMessage)) -> MockToolMode {
  case latest_user_content(messages) {
    Some(content) ->
      case string.contains(content, "[tool-loop-error]") {
        True -> MockToolLoopError
        False ->
          case string.contains(content, "[tool-loop-success]") {
            True -> MockToolLoopSuccess
            False -> MockToolDefault
          }
      }
    None -> MockToolDefault
  }
}

fn latest_user_content(messages: List(provider.ChatMessage)) -> Option(String) {
  latest_user_content_acc(messages, None)
}

fn latest_user_content_acc(
  messages: List(provider.ChatMessage),
  latest: Option(String),
) -> Option(String) {
  case messages {
    [] -> latest
    [message, ..rest] ->
      case message.role == "user" {
        True -> latest_user_content_acc(rest, Some(message.content))
        False -> latest_user_content_acc(rest, latest)
      }
  }
}

fn mock_arguments_for_tool(tool_name: String, mode: MockToolMode) -> String {
  case mode {
    MockToolLoopError -> "{}"
    _ ->
      case tool_name {
        "safe_shell" -> "{\"command\":\"pwd\"}"
        "canvas" -> "{\"action\":\"create\",\"title\":\"Scratchpad\"}"
        "gateway" -> "{\"action\":\"describe\"}"
        "github" -> "{\"action\":\"get_my_repos\"}"
        "web_fetch" -> "{\"url\":\"https://example.com\"}"
        "git_inspect" -> "{\"action\":\"status\"}"
        "file_system" -> "{\"action\":\"list\",\"path\":\".\"}"
        _ -> "{}"
      }
  }
}
