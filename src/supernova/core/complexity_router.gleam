import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/llm/provider

pub type ComplexityTier {
  Fast
  Balanced
  Capable
  Maximum
}

pub type ComplexityDecision {
  ComplexityDecision(
    score: Float,
    tier: ComplexityTier,
    selected_config: provider.ProviderConfig,
  )
}

pub fn route(
  base_config: provider.ProviderConfig,
  messages: List(provider.ChatMessage),
  tool_count: Int,
  depth: Int,
) -> ComplexityDecision {
  let token_factor = token_factor(messages)
  let tools_factor = clamp(int.to_float(tool_count) /. 10.0)
  let depth_factor = clamp(int.to_float(depth) /. 8.0)
  let world_factor = case has_world_model_context(messages) {
    True -> 1.0
    False -> 0.0
  }
  let keyword_factor = case has_analysis_keywords(messages) {
    True -> 1.0
    False -> 0.0
  }
  let history_factor = case list.length(messages) > 20 {
    True -> 1.0
    False -> 0.0
  }

  let score =
    clamp(
      token_factor
      *. 0.2
      +. tools_factor
      *. 0.15
      +. depth_factor
      *. 0.2
      +. world_factor
      *. 0.1
      +. keyword_factor
      *. 0.2
      +. history_factor
      *. 0.15,
    )
  let tier = tier_for_score(score)
  let selected_model = select_model(base_config, tier)
  let selected_config =
    provider.ProviderConfig(..base_config, default_model: selected_model)
  ComplexityDecision(score: score, tier: tier, selected_config: selected_config)
}

pub fn tier_for_score(score: Float) -> ComplexityTier {
  case score {
    x if x <. 0.25 -> Fast
    x if x <. 0.55 -> Balanced
    x if x <. 0.8 -> Capable
    _ -> Maximum
  }
}

pub fn tier_to_string(tier: ComplexityTier) -> String {
  case tier {
    Fast -> "fast"
    Balanced -> "balanced"
    Capable -> "capable"
    Maximum -> "maximum"
  }
}

fn select_model(
  config: provider.ProviderConfig,
  tier: ComplexityTier,
) -> String {
  case has_user_override(config) {
    True -> config.default_model
    False ->
      case config.name, tier {
        "anthropic", Fast -> "claude-haiku-4.5"
        "anthropic", _ -> "claude-sonnet-4-5"
        "openai", Fast -> "gpt-5-mini"
        "openai", Balanced -> "gpt-5-mini"
        "openai", Capable -> "gpt-5"
        "openai", Maximum -> "gpt-5"
        "mock", _ -> config.default_model
        _, _ -> config.default_model
      }
  }
}

fn has_user_override(config: provider.ProviderConfig) -> Bool {
  case expected_default_model(config.name) {
    Some(expected) -> expected != config.default_model
    None -> False
  }
}

fn expected_default_model(provider_name: String) -> Option(String) {
  case provider_name {
    "anthropic" -> Some("claude-sonnet-4-5")
    "openai" -> Some("gpt-5-mini")
    "mock" -> Some("mock-model")
    _ -> None
  }
}

fn token_factor(messages: List(provider.ChatMessage)) -> Float {
  let chars =
    messages
    |> list.map(fn(msg) { string.length(msg.content) })
    |> list.fold(0, fn(acc, value) { acc + value })
  let estimated_tokens = chars / 4
  clamp(int.to_float(estimated_tokens) /. 1200.0)
}

fn has_world_model_context(messages: List(provider.ChatMessage)) -> Bool {
  list.any(messages, fn(msg) {
    msg.role == "system"
    && string.contains(msg.content, "## CONTEXTO DO WORLD MODEL")
  })
}

fn has_analysis_keywords(messages: List(provider.ChatMessage)) -> Bool {
  let joined =
    messages
    |> list.map(fn(msg) { msg.content })
    |> string.join(" ")
    |> string.lowercase
  string.contains(joined, "analise")
  || string.contains(joined, "compare")
  || string.contains(joined, "projete")
}

fn clamp(value: Float) -> Float {
  case value <. 0.0 {
    True -> 0.0
    False ->
      case value >. 1.0 {
        True -> 1.0
        False -> value
      }
  }
}
