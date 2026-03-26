//// Kimi Provider — Moonshot AI models via OpenAI-compatible API.
////
//// Kimi exposes an OpenAI-compatible chat endpoint, so this adapter delegates
//// to the shared `openai_compatible` implementation.
////
//// API base: https://api.moonshot.cn/v1/chat/completions
////
//// ## Usage
////
//// ```yaml
//// providers:
////   default:
////     type: kimi
////     model: moonshot-v1-8k
////     # api_key via SUPERNOVA_KIMI_API_KEY
//// ```

import supernova/llm/provider
import supernova/llm/providers/openai_compatible

const api_url = "https://api.moonshot.cn/v1/chat/completions"

/// Default Kimi model for general use.
pub const default_model = "moonshot-v1-8k"

/// Send a chat completion request via Kimi (Moonshot AI).
pub fn chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  openai_compatible.chat(
    messages,
    config,
    tools,
    base_url: api_url,
    extra_headers: [],
  )
}
