//// Provider information for wizard and model selection.
////
//// Mirrors nullclaw's onboard ProviderInfo for provider selection.
////
//// ## Usage
////
//// ```gleam
//// import supernova/llm/providers_info
////
//// let providers = providers_info.known_providers
//// ```
////

import gleam/list
import gleam/option.{type Option, None, Some}

// Provider information record
pub type ProviderInfo {
  ProviderInfo(
    key: String,
    label: String,
    description: String,
    default_model: String,
    env_var: String,
  )
}

// List of providers currently supported by the runtime/config contract.
pub fn known_providers() -> List(ProviderInfo) {
  [
    ProviderInfo(
      key: "openrouter",
      label: "OpenRouter",
      description: "Multi-provider gateway (recommended)",
      default_model: "anthropic/claude-haiku-4-5",
      env_var: "OPENROUTER_API_KEY",
    ),
    ProviderInfo(
      key: "anthropic",
      label: "Anthropic",
      description: "Claude direct access",
      default_model: "claude-sonnet-4-20250514",
      env_var: "ANTHROPIC_API_KEY",
    ),
    ProviderInfo(
      key: "openai",
      label: "OpenAI",
      description: "GPT direct access",
      default_model: "gpt-4o",
      env_var: "OPENAI_API_KEY",
    ),
    ProviderInfo(
      key: "minimax",
      label: "MiniMax",
      description: "MiniMax models",
      default_model: "MiniMax-Text-01",
      env_var: "MINIMAX_API_KEY",
    ),
    ProviderInfo(
      key: "opencode_zen",
      label: "OpenCode Zen",
      description: "Pay-as-you-go gateway for Claude and OpenAI-compatible models",
      default_model: "claude-sonnet-4-6",
      env_var: "OPENCODE_ZEN_API_KEY",
    ),
    ProviderInfo(
      key: "zhipu",
      label: "Zhipu",
      description: "GLM chat models",
      default_model: "glm-4-plus",
      env_var: "ZHIPU_API_KEY",
    ),
    ProviderInfo(
      key: "zhipu_coding",
      label: "Zhipu Coding",
      description: "CodeGeeX coding models",
      default_model: "codegeex-4",
      env_var: "ZHIPU_API_KEY",
    ),
    ProviderInfo(
      key: "zai",
      label: "Z.AI",
      description: "Zhipu AI new platform (智谱AI z.ai)",
      default_model: "glm-4.7",
      env_var: "ZAI_API_KEY",
    ),
    ProviderInfo(
      key: "zai_coding",
      label: "Z.AI Coding",
      description: "Zhipu AI coding plan on z.ai",
      default_model: "codegeex-4.6",
      env_var: "ZAI_API_KEY",
    ),
    ProviderInfo(
      key: "mistral",
      label: "Mistral",
      description: "Mistral API, also serving DeepSeek models",
      default_model: "deepseek-v4-1-flash-1017",
      env_var: "MISTRAL_API_KEY",
    ),
    ProviderInfo(
      key: "gemini",
      label: "Gemini",
      description: "Google Gemini, through the Gemini API (generateContent)",
      default_model: "gemini-3.8-flash",
      env_var: "GEMINI_API_KEY",
    ),
    ProviderInfo(
      key: "ollama",
      label: "Ollama",
      description: "Local/self-hosted models",
      default_model: "llama3",
      env_var: "OLLAMA_HOST",
    ),
  ]
}

// Get provider info by key
pub fn get_provider(key: String) -> Option(ProviderInfo) {
  case list.find(known_providers(), fn(p) { p.key == key }) {
    Ok(p) -> Some(p)
    Error(_) -> None
  }
}

// Get default model for a provider
pub fn default_model_for_provider(key: String) -> String {
  case get_provider(key) {
    Some(p) -> p.default_model
    None -> "gpt-4o"
  }
}

// Get environment variable hint for a provider
pub fn env_var_for_provider(key: String) -> String {
  case get_provider(key) {
    Some(p) -> p.env_var
    None -> "API_KEY"
  }
}
