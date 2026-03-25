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

import gleam/option.{None}
import supernova/llm/provider
import supernova/llm/providers/minimax
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
    "openai" -> openai_chat(messages, config, tools)
    "anthropic" -> anthropic_chat(messages, config, tools)
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
  _messages: List(provider.ChatMessage),
  _config: provider.ProviderConfig,
  _tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  Ok(provider.ChatResponse(
    role: "assistant",
    content: "Mock response",
    tool_calls: None,
    reasoning_content: None,
  ))
}

// ============================================================================
// OpenAI Provider (placeholder — full impl in 2.3)
// ============================================================================

/// OpenAI chat completion — placeholder.
fn openai_chat(
  _messages: List(provider.ChatMessage),
  _config: provider.ProviderConfig,
  _tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  Error(provider.ConfigError(reason: "OpenAI provider not yet implemented"))
}

// ============================================================================
// Anthropic Provider (placeholder — full impl in 2.4)
// ============================================================================

/// Anthropic chat completion — placeholder.
fn anthropic_chat(
  _messages: List(provider.ChatMessage),
  _config: provider.ProviderConfig,
  _tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  Error(provider.ConfigError(reason: "Anthropic provider not yet implemented"))
}
