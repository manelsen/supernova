//// OpenAI-Compatible Provider — generic adapter for OpenAI-protocol APIs.
////
//// Handles any provider that speaks the OpenAI chat completions protocol:
//// OpenCode Zen, OpenRouter, Zhipu, Minimax, and others.
////
//// ## Usage
////
//// ```gleam
//// openai_compatible.chat(messages, config, tools,
////   base_url: "https://openrouter.ai/api/v1/chat/completions",
////   extra_headers: [#("http-referer", "https://supernova.ai")],
//// )
//// ```

import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import supernova/llm/provider
import supernova/llm/providers/openai

// ============================================================================
// Public API
// ============================================================================

/// Send a chat completion request to any OpenAI-compatible endpoint.
///
/// - `base_url` — full URL including path, e.g. `https://openrouter.ai/api/v1/chat/completions`
/// - `extra_headers` — provider-specific headers beyond Authorization and Content-Type
pub fn chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
  base_url base_url: String,
  extra_headers extra_headers: List(#(String, String)),
) -> Result(provider.ChatResponse, provider.LLMError) {
  let body = openai.build_request_body(messages, config.default_model, tools)

  case config.api_key {
    Some(api_key) -> {
      case do_request(body, api_key, base_url, extra_headers) {
        Ok(response_body) -> openai.parse_response(response_body)
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
