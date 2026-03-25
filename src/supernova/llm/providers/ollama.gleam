//// Ollama Provider — chat completion via local Ollama API.
////
//// Uses the OpenAI-compatible endpoint at localhost:11434.

import gleam/option.{Some}
import supernova/llm/provider
import supernova/llm/providers/openai

const ollama_url = "http://localhost:11434/v1/chat/completions"

/// Send a chat completion request to a local Ollama instance.
///
/// Uses the OpenAI-compatible API endpoint.
pub fn chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  let ollama_config =
    provider.ProviderConfig(
      name: "openai",
      api_key: Some("ollama"),
      base_url: Some(ollama_url),
      default_model: config.default_model,
    )

  // Delegate to OpenAI provider with Ollama's base URL
  openai.chat(messages, ollama_config, tools)
}
