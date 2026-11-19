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
  MockToolWriteSelf
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

@external(erlang, "supernova_mock_ffi", "network_fail_once")
fn mock_network_fail_once(key: String) -> Bool

@external(erlang, "supernova_mock_ffi", "record_prompt")
fn record_prompt(prompt: String) -> Nil

/// Mock chat completion — returns a canned response.
fn mock_chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  record_prompt(
    messages
    |> list.map(fn(message) { message.content })
    |> string.join("\n---\n"),
  )
  case latest_user_content(messages) {
    Some(content) -> {
      case string.contains(content, "[mock-crash]") {
        True -> panic as "simulated executor crash"
        False -> Nil
      }
      case mock_forced_error(content) {
        Some(error) -> Error(error)
        None -> mock_chat_success(messages, config, tools)
      }
    }
    None -> mock_chat_success(messages, config, tools)
  }
}

fn mock_chat_success(
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

fn mock_forced_error(content: String) -> Option(provider.LLMError) {
  case string.contains(content, "[mock-network-fail-once]") {
    True ->
      case mock_network_fail_once(content) {
        True -> Some(provider.NetworkError("mock network failure"))
        False -> None
      }
    False ->
      case string.contains(content, "[mock-429]") {
        True -> Some(provider.APIError(status: 429, message: "mock rate limit"))
        False ->
          case string.contains(content, "[mock-400]") {
            True ->
              Some(provider.APIError(status: 400, message: "mock bad request"))
            False -> None
          }
      }
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
    [first_tool, ..], False -> {
      let #(tool_name, tool_arguments) = case tool_mode {
        MockToolWriteSelf -> #(
          "file_system",
          "{\"action\":\"write\",\"path\":\"../self/core.json\",\"content\":\"tampered\"}",
        )
        _ -> #(
          first_tool.name,
          mock_arguments_for_tool(first_tool.name, tool_mode),
        )
      }
      Ok(provider.ChatResponse(
        role: "assistant",
        content: "",
        tool_calls: Some([
          provider.ToolCall(
            id: "mock_tool_call_1",
            name: tool_name,
            arguments: tool_arguments,
          ),
        ]),
        reasoning_content: None,
      ))
    }
  }
}

fn special_mock_response(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
) -> Option(String) {
  let system_text =
    messages
    |> list.filter(fn(message) { message.role == "system" })
    |> list.map(fn(message) { message.content })
    |> string.join("\n")
  let is_reflection =
    string.contains(system_text, "Responda APENAS com JSON estrito")
  case is_reflection, latest_user_content(messages) {
    True, Some(content) ->
      case string.contains(content, "Reflita agora") {
        True ->
          case
            string.contains(system_text, "[mock-invalid-reflection]"),
            string.contains(system_text, "[mock-fenced-reflection]")
          {
            True, _ -> Some("not json")
            False, True ->
              Some("```json\n" <> reflection_mock_json(system_text) <> "\n```")
            False, False -> Some(reflection_mock_json(system_text))
          }
        False -> special_mock_response_plain(messages, config)
      }
    _, _ -> special_mock_response_plain(messages, config)
  }
}

fn reflection_mock_json(system_text: String) -> String {
  let experiences =
    "{\"experiences\":[{\"text\":\"Aprendi a confiar no que foi vivido.\"}],"
  case reflection_neighbor(system_text) {
    Some(#(from, to)) ->
      experiences
      <> "\"pressures\":[{\"from\":\""
      <> from
      <> "\",\"to\":\""
      <> to
      <> "\",\"strength\":0.9,\"reason\":\"Aprendi com a convivência.\"}]}"
    None -> experiences <> "\"pressures\":[]}"
  }
}

fn reflection_neighbor(system_text: String) -> Option(#(String, String)) {
  case string.split(system_text, "Vizinhos coerentes:\n") {
    [_, rest] -> {
      let found =
        rest
        |> string.split("\n")
        |> list.find_map(fn(line) {
          let stripped = string.trim(line)
          case string.starts_with(stripped, "- ") {
            False -> Error(Nil)
            True -> {
              let body = string.drop_start(stripped, 2)
              case string.split(body, " -> ") {
                [from, target] -> {
                  let to = case string.split(target, " — ") {
                    [id, ..] -> id
                    _ -> target
                  }
                  Ok(#(from, string.trim(to)))
                }
                _ -> Error(Nil)
              }
            }
          }
        })
      case found {
        Ok(pair) -> Some(pair)
        Error(_) -> None
      }
    }
    _ -> None
  }
}

fn special_mock_response_plain(
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
                False ->
                  case string.contains(content, "[long-response]") {
                    True -> Some(string.repeat("A", 9000))
                    False -> None
                  }
              }
          }
      }
    None -> None
  }
}

fn mock_tool_mode(messages: List(provider.ChatMessage)) -> MockToolMode {
  case latest_user_content(messages) {
    Some(content) ->
      case string.contains(content, "[mock-write-self]") {
        True -> MockToolWriteSelf
        False ->
          case string.contains(content, "[tool-loop-error]") {
            True -> MockToolLoopError
            False ->
              case string.contains(content, "[tool-loop-success]") {
                True -> MockToolLoopSuccess
                False -> MockToolDefault
              }
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
