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

import gleam/dynamic/decode
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
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
  // The host is read from the parsed URL, as the HTTP client reads it: a
  // prefix check let "http://localhost:8080@remote.example" through.
  let allowed = case uri.parse(string.trim(base_url)) {
    Ok(parsed) -> {
      let scheme = option.map(parsed.scheme, string.lowercase)
      let host = option.map(parsed.host, string.lowercase)
      case scheme, host {
        Some("https"), Some(_) -> True
        Some("http"), Some(host) ->
          name == "ollama"
          || list.contains(["localhost", "127.0.0.1", "::1", "[::1]"], host)
        _, _ -> False
      }
    }
    Error(_) -> False
  }
  case allowed {
    True -> Ok(Nil)
    False ->
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
        status -> {
          io.println(
            "LLM provider error: status="
            <> int.to_string(status)
            <> " "
            <> error_summary(response.body),
          )
          Error("API error " <> string.inspect(status) <> ": " <> response.body)
        }
      }
    }
    Error(error) -> {
      io.println("LLM provider error: transport " <> string.inspect(error))
      Error("Network error connecting to " <> base_url)
    }
  }
}

/// A one-line, log-safe summary of a provider error body: the error type,
/// where it points and its reason. Validation errors echo the offending
/// input, which can be conversation text, so the input is never included.
pub fn error_summary(body: String) -> String {
  let validation = {
    let loc_part =
      decode.one_of(decode.string, [decode.int |> decode.map(int.to_string)])
    let item = {
      use kind <- decode.field("type", decode.string)
      use loc <- decode.optional_field("loc", [], decode.list(loc_part))
      use msg <- decode.optional_field("msg", "", decode.string)
      decode.success(kind <> " at " <> string.join(loc, ".") <> ": " <> msg)
    }
    decode.at(["detail"], decode.list(item))
    |> decode.map(string.join(_, "; "))
  }
  let flat = {
    use kind <- decode.optional_field("type", "error", decode.string)
    use message <- decode.field("message", decode.string)
    decode.success(kind <> ": " <> message)
  }
  let nested = decode.at(["error"], flat)

  case json.parse(body, decode.one_of(validation, [nested, flat])) {
    Ok(summary) -> string.slice(summary, 0, 300)
    Error(_) ->
      "unparsed body, " <> int.to_string(string.byte_size(body)) <> " bytes"
  }
}
