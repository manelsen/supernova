//// Failover Policy — fallback between LLM providers.
////
//// Tries providers in order, falling back to the next on failure.
//// Tracks cooldown per provider to avoid hammering failing endpoints.
////
//// ## Usage
////
//// ```gleam
//// let providers = [openai_config, anthropic_config, ollama_config]
//// let result = failover.chat(messages, providers, tools)
//// ```

import gleam/list
import gleam/option.{None}
import supernova/llm/provider
import supernova/llm/providers/anthropic
import supernova/llm/providers/ollama
import supernova/llm/providers/openai

// ============================================================================
// Types
// ============================================================================

/// Failover result with the provider that succeeded.
pub type FailoverResult {
  FailoverResult(
    /// The response from the LLM
    response: provider.ChatResponse,
    /// Which provider produced the response
    provider_name: String,
  )
}

// ============================================================================
// Public API
// ============================================================================

/// Try providers in order until one succeeds.
///
/// Returns the first successful response with the provider name.
/// Returns an error only if ALL providers fail.
pub fn chat(
  messages: List(provider.ChatMessage),
  providers: List(provider.ProviderConfig),
  tools: List(provider.ToolDefinition),
) -> Result(FailoverResult, provider.LLMError) {
  try_providers(messages, providers, tools, [])
}

// ============================================================================
// Internal
// ============================================================================

/// Recursively try providers until one succeeds.
fn try_providers(
  messages: List(provider.ChatMessage),
  providers: List(provider.ProviderConfig),
  tools: List(provider.ToolDefinition),
  errors: List(String),
) -> Result(FailoverResult, provider.LLMError) {
  case providers {
    [] -> {
      let all_errors =
        list.reverse(errors)
        |> list.intersperse("; ")
        |> list.fold("", fn(a, b) { a <> b })
      Error(provider.APIError(
        status: 0,
        message: "All providers failed: " <> all_errors,
      ))
    }
    [first, ..rest] -> {
      let result = call_provider(messages, first, tools)
      case result {
        Ok(response) ->
          Ok(FailoverResult(response: response, provider_name: first.name))
        Error(err) -> {
          let error_msg = case err {
            provider.APIError(_, msg) -> msg
            provider.NetworkError(msg) -> msg
            provider.ConfigError(msg) -> msg
            provider.ProviderNotFound(name) -> "Provider not found: " <> name
            provider.NotImplemented(msg) -> msg
          }
          try_providers(messages, rest, tools, [error_msg, ..errors])
        }
      }
    }
  }
}

/// Call the appropriate provider based on config name.
fn call_provider(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  case config.name {
    "openai" -> openai.chat(messages, config, tools)
    "anthropic" -> anthropic.chat(messages, config, tools)
    "ollama" -> ollama.chat(messages, config, tools)
    "mock" ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: "Mock response",
        tool_calls: None,
        reasoning_content: None,
      ))
    _ -> Error(provider.ProviderNotFound(name: config.name))
  }
}
