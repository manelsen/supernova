//// OpenRouter Provider — unified API for 300+ models.
////
//// OpenRouter routes requests to the best available provider for a given model.
//// Useful as a single API key that covers OpenAI, Anthropic, Google, Meta, and more.
////
//// App-attribution headers sent automatically:
////   - `HTTP-Referer: https://supernova.ai`      — primary app identifier for rankings
////   - `X-OpenRouter-Title: Supernova`            — display name in analytics
////   - `X-OpenRouter-Categories: coding-agent`    — marketplace category
////
//// For per-conversation observability, pass `x-session-id` via extra_headers
//// when calling `openai_compatible.chat` directly:
////   extra_headers: [#("x-session-id", session_id)]
////
//// API base: https://openrouter.ai/api/v1
//// Models: https://openrouter.ai/models
////
//// ## Usage
////
//// ```yaml
//// # supernova.yaml
//// providers:
////   default:
////     provider: openrouter
////     model: anthropic/claude-haiku-4-5   # or any openrouter model id
////     # api_key via SUPERNOVA_OPENROUTER_API_KEY
//// ```

import supernova/llm/provider
import supernova/llm/providers/openai_compatible

// ============================================================================
// Constants
// ============================================================================

const api_url = "https://openrouter.ai/api/v1/chat/completions"

/// Default model — Claude Haiku 4.5 via OpenRouter (fast and cheap).
/// Use full OpenRouter model IDs: "anthropic/claude-opus-4-6", "openai/gpt-4o", etc.
pub const default_model = "anthropic/claude-haiku-4-5"

// OpenRouter app-attribution headers.
// `HTTP-Referer` is the primary app identifier for rankings.
// `X-OpenRouter-Title` is the canonical title header (`X-Title` is legacy).
// `X-OpenRouter-Categories` places the app in marketplace categories.
const referer_header = #("http-referer", "https://supernova.ai")

const title_header = #("x-openrouter-title", "Supernova")

const categories_header = #("x-openrouter-categories", "coding-agent")

// ============================================================================
// Public API
// ============================================================================

/// Send a chat completion request via OpenRouter.
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
    extra_headers: [referer_header, title_header, categories_header],
  )
}
