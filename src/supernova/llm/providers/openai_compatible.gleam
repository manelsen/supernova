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

  case config.api_key, secure_endpoint(config.name, base_url) {
    Some(_), Error(reason) -> Error(provider.ConfigError(reason: reason))
    Some(api_key), Ok(Nil) -> {
      case do_request(body, api_key, base_url, extra_headers) {
        Ok(response_body) -> openai.parse_response(response_body)
        Error(reason) -> Error(provider.NetworkError(reason: reason))
      }
    }
    None, _ ->
      Error(provider.ConfigError(
        reason: "No API key configured for " <> config.name,
      ))
  }
}

/// The API key travels only over HTTPS. Plain HTTP is allowed for loopback
/// hosts and for Ollama, whose key is a placeholder and which often runs on a
/// private network under a service name.
pub fn secure_endpoint(name: String, base_url: String) -> Result(Nil, String) {
  let url = string.lowercase(string.trim(base_url))
  let loopback =
    list.any(
      ["http://localhost", "http://127.0.0.1", "http://[::1]"],
      fn(prefix) {
        url == prefix
        || string.starts_with(url, prefix <> ":")
        || string.starts_with(url, prefix <> "/")
      },
    )
  case string.starts_with(url, "https://"), loopback, name == "ollama" {
    True, _, _ | _, True, _ | _, _, True -> Ok(Nil)
    False, False, False ->
      Error("Refusing to send the " <> name <> " API key over a non-HTTPS URL")
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
