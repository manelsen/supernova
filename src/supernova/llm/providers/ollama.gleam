//// Ollama Provider — chat completion via local Ollama API.
////
//// Uses the OpenAI-compatible endpoint at localhost:11434.

import gleam/option.{None, Some}
import supernova/llm/provider
import supernova/llm/providers/openai_compatible

const default_ollama_url = "http://localhost:11434/v1/chat/completions"

/// Send a chat completion request to a local Ollama instance.
///
/// Uses the OpenAI-compatible API endpoint.
pub fn chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  let base_url = case config.base_url {
    Some(url) -> url
    None -> default_ollama_url
  }

  let ollama_config =
    provider.ProviderConfig(
      name: "ollama",
      api_key: Some("ollama"),
      base_url: Some(base_url),
      default_model: config.default_model,
    )

  openai_compatible.chat(
    messages,
    ollama_config,
    tools,
    base_url: base_url,
    extra_headers: [],
  )
}
