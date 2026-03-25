//// OpenCode Zen Provider — pay-as-you-go token API at opencode.ai.
////
//// OpenCode Zen routes to different backends depending on the model family.
//// The endpoint format and auth headers vary per family:
////
////   - Claude models  → /zen/v1/messages   (Anthropic Messages format)
////   - OpenAI-compat  → /zen/v1/chat/completions  (OpenAI Chat format)
////     (covers GLM, MiniMax, Kimi, DeepSeek, Qwen, and similar)
////
//// GPT Responses API and Gemini native endpoints are NOT yet supported here;
//// those model families will return a clear ConfigError.
////
//// Auth: Bearer token for all endpoints (not x-api-key).
////
//// ## Usage
////
//// ```yaml
//// # supernova.yaml
//// providers:
////   default:
////     provider: opencode_zen
////     model: claude-sonnet-4-6   # or: glm-4.7, kimi-k2, deepseek-coder-v2
////     # api_key via SUPERNOVA_OPENCODE_ZEN_API_KEY
//// ```

import gleam/string
import supernova/llm/provider
import supernova/llm/providers/anthropic_compatible
import supernova/llm/providers/openai_compatible

// ============================================================================
// Constants
// ============================================================================

const anthropic_url = "https://opencode.ai/zen/v1/messages"

const openai_compat_url = "https://opencode.ai/zen/v1/chat/completions"

/// Default model — Claude Sonnet 4.6 (coding-optimised, lower cost than Opus).
/// Alternatives: "claude-opus-4-6", "glm-4.7" (free tier), "kimi-k2".
pub const default_model = "claude-sonnet-4-6"

// ============================================================================
// Public API
// ============================================================================

/// Send a chat completion request via OpenCode Zen.
///
/// Dispatches to the correct endpoint based on the model prefix:
/// - "claude-*"  → Anthropic Messages format  (/zen/v1/messages)
/// - everything else → OpenAI Chat format  (/zen/v1/chat/completions)
///
/// GPT-native (gpt-5.x Responses API) and Gemini-native models are not yet
/// supported and will return `ConfigError`.
pub fn chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  let model = config.default_model
  case model_family(model) {
    AnthropicFamily ->
      anthropic_compatible.chat(
        messages,
        config,
        tools,
        base_url: anthropic_url,
        extra_headers: [],
      )
    OpenAICompatFamily ->
      openai_compatible.chat(
        messages,
        config,
        tools,
        base_url: openai_compat_url,
        extra_headers: [],
      )
    UnsupportedFamily(reason) -> Error(provider.NotImplemented(reason: reason))
  }
}

// ============================================================================
// Internal — model family detection
// ============================================================================

type ModelFamily {
  AnthropicFamily
  OpenAICompatFamily
  UnsupportedFamily(reason: String)
}

fn model_family(model: String) -> ModelFamily {
  case string.starts_with(model, "claude-") {
    True -> AnthropicFamily
    False ->
      case
        string.starts_with(model, "gpt-")
        || string.starts_with(model, "o1-")
        || string.starts_with(model, "o3-")
        || string.starts_with(model, "o4-")
      {
        True ->
          UnsupportedFamily(
            reason: "OpenCode Zen GPT models use the Responses API which is not yet supported. "
            <> "Use provider 'openai' for GPT models.",
          )
        False ->
          case string.starts_with(model, "gemini-") {
            True ->
              UnsupportedFamily(
                reason: "OpenCode Zen Gemini models use a per-model Google AI endpoint "
                <> "(/zen/v1/models/{modelId}) which is not yet supported. "
                <> "Use provider 'gemini' for Gemini models.",
              )
            False -> OpenAICompatFamily
          }
      }
  }
}
