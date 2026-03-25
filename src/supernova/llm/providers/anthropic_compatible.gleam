//// Anthropic-Compatible Provider — generic adapter for Anthropic Messages protocol.
////
//// Handles any endpoint that speaks the Anthropic Messages API format
//// with Bearer token auth (as opposed to x-api-key used by the native adapter).
////
//// Used by OpenCode Zen for Claude models: the endpoint is Anthropic Messages
//// format but authentication is Bearer token, not x-api-key.
////
//// ## Usage
////
//// ```gleam
//// anthropic_compatible.chat(messages, config, tools,
////   base_url: "https://opencode.ai/zen/v1/messages",
////   extra_headers: [],
//// )
//// ```

import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import supernova/llm/provider
import supernova/llm/providers/anthropic

// ============================================================================
// Public API
// ============================================================================

/// Send an Anthropic Messages API request to any compatible endpoint.
///
/// Uses `Authorization: Bearer` (for proxies like OpenCode Zen).
/// The native Anthropic adapter uses `x-api-key` instead.
pub fn chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
  base_url base_url: String,
  extra_headers extra_headers: List(#(String, String)),
) -> Result(provider.ChatResponse, provider.LLMError) {
  let body = anthropic.build_request_body(messages, config.default_model, tools)

  case config.api_key {
    Some(api_key) -> {
      case do_request(body, api_key, base_url, extra_headers) {
        Ok(response_body) -> anthropic.parse_response(response_body)
        Error(reason) -> Error(provider.NetworkError(reason: reason))
      }
    }
    None ->
      Error(provider.ConfigError(
        reason: "No API key configured for " <> config.name,
      ))
  }
}

// ============================================================================
// HTTP
// ============================================================================

fn do_request(
  body: String,
  api_key: String,
  base_url: String,
  extra_headers: List(#(String, String)),
) -> Result(String, String) {
  let assert Ok(req) = request.to(base_url)

  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("authorization", "Bearer " <> api_key)
    |> request.set_header("anthropic-version", "2023-06-01")
    |> request.set_body(body)

  let req =
    list.fold(extra_headers, req, fn(r, h) { request.set_header(r, h.0, h.1) })

  case hackney.send(req) {
    Ok(response) -> {
      case response.status {
        200 -> Ok(response.body)
        status ->
          Error("API error " <> string.inspect(status) <> ": " <> response.body)
      }
    }
    Error(_) -> Error("Network error connecting to " <> base_url)
  }
}
