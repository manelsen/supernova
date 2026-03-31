//// Failover Policy — fallback between LLM providers.
////
//// Tries providers in order, falling back to the next on failure.
//// Returns ProviderNotFound if the provider name is not recognised.
////
//// Supports optional exponential cooldown per provider via FailoverCooldownActor.
////
//// ## Usage
////
//// ```gleam
//// let providers = [openai_config, anthropic_config, ollama_config]
//// let result = failover.chat(messages, providers, tools)
//// ```
////
//// With cooldown:
//// ```gleam
//// let assert Ok(cooldown_actor) = failover_cooldown_actor.start(failover_cooldown.default_config())
//// let result = failover.chat_with_cooldown(messages, providers, tools, cooldown_actor)
//// ```

import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import supernova/llm/failover_cooldown/actor as cd_actor
import supernova/llm/failover_cooldown/types as cd_types
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
pub fn chat(
  messages: List(provider.ChatMessage),
  providers: List(provider.ProviderConfig),
  tools: List(provider.ToolDefinition),
) -> Result(FailoverResult, provider.LLMError) {
  try_providers(messages, providers, tools, [])
}

/// Try providers in order with per-provider exponential cooldown.
///
/// Skips providers that are in cooldown. Records failures and successes
/// to the cooldown actor for exponential backoff (30s → 60s → 120s → max 5min).
pub fn chat_with_cooldown(
  messages: List(provider.ChatMessage),
  providers: List(provider.ProviderConfig),
  tools: List(provider.ToolDefinition),
  cooldown_actor: process.Subject(cd_actor.CooldownCommand),
) -> Result(FailoverResult, provider.LLMError) {
  try_providers_with_cooldown(messages, providers, tools, [], cooldown_actor)
}

// ============================================================================
// Internal
// ============================================================================

/// Recursively try providers until one succeeds (no cooldown).
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

/// Recursively try providers with cooldown check.
fn try_providers_with_cooldown(
  messages: List(provider.ChatMessage),
  providers: List(provider.ProviderConfig),
  tools: List(provider.ToolDefinition),
  errors: List(String),
  cooldown_actor: process.Subject(cd_actor.CooldownCommand),
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
      let in_cooldown =
        actor.call(
          cooldown_actor,
          waiting: 5000,
          sending: cd_actor.CheckCooldown(first.name, _),
        )
      case in_cooldown {
        cd_types.InCooldown(_, _) -> {
          let skip_msg = "Provider " <> first.name <> " in cooldown, skipping"
          try_providers_with_cooldown(
            messages,
            rest,
            tools,
            [skip_msg, ..errors],
            cooldown_actor,
          )
        }
        cd_types.NotInCooldown -> {
          let result = call_provider(messages, first, tools)
          case result {
            Ok(response) -> {
              let _ =
                actor.call(
                  cooldown_actor,
                  waiting: 5000,
                  sending: cd_actor.RecordSuccess(first.name, _),
                )
              Ok(FailoverResult(response: response, provider_name: first.name))
            }
            Error(err) -> {
              let _ =
                actor.call(
                  cooldown_actor,
                  waiting: 5000,
                  sending: cd_actor.RecordFailure(first.name, _),
                )
              let error_msg = case err {
                provider.APIError(_, msg) -> msg
                provider.NetworkError(msg) -> msg
                provider.ConfigError(msg) -> msg
                provider.ProviderNotFound(name) ->
                  "Provider not found: " <> name
                provider.NotImplemented(msg) -> msg
              }
              try_providers_with_cooldown(
                messages,
                rest,
                tools,
                [error_msg, ..errors],
                cooldown_actor,
              )
            }
          }
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
    _ -> Error(provider.ProviderNotFound(name: config.name))
  }
}
