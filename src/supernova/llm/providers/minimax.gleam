//// Minimax Provider — MiniMax-Text and abab models.
////
//// MiniMax offers long-context models (up to 4M tokens) optimised for
//// document understanding, multi-turn conversation, and agentic tasks.
////
//// The v2 API (`text/chatcompletion_v2`) is OpenAI-compatible: tool definitions
//// use `tools` + `type:"function"`, responses use `tool_calls`, and tool results
//// use `role:"tool"` — identical to the OpenAI chat completions format.
////
//// Minimax-specific response fields:
////   - `base_resp` — `{status_code, status_msg}` — may be non-zero on HTTP 200
////     (e.g. content filter triggered). We surface these as `APIError`.
////   - `input_sensitive` / `output_sensitive` — boolean content-filter flags.
////
//// API base:  https://api.minimax.io/v1  (new domain; api.minimax.chat is legacy)
//// Endpoint:  /v1/text/chatcompletion_v2
//// Docs:      https://platform.minimaxi.com/document/ChatCompletion%20v2
////
//// ## Usage
////
//// ```yaml
//// # supernova.yaml
//// providers:
////   default:
////     provider: minimax
////     model: MiniMax-Text-01      # or: abab6.5s-chat, abab6.5g-chat
////     # api_key via SUPERNOVA_MINIMAX_API_KEY
//// ```

import gleam/dynamic/decode
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import supernova/llm/provider
import supernova/llm/providers/openai

// ============================================================================
// Constants
// ============================================================================

// v2 endpoint on the new domain (api.minimax.chat is legacy/deprecated).
const api_url = "https://api.minimax.io/v1/text/chatcompletion_v2"

/// Default model — MiniMax-Text-01 (up to 4M context window).
/// Alternatives: "abab6.5s-chat" (fast/cheap), "abab6.5g-chat" (balanced).
pub const default_model = "MiniMax-Text-01"

// ============================================================================
// Public API
// ============================================================================

/// Send a chat completion request via MiniMax (v2 API).
pub fn chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  let body = openai.build_request_body(messages, config.default_model, tools)

  case config.api_key {
    None ->
      Error(provider.ConfigError(
        reason: "No API key configured for " <> config.name,
      ))
    Some(api_key) -> {
      case do_request(body, api_key) {
        Ok(response_body) -> parse_response(response_body)
        Error(reason) -> Error(provider.NetworkError(reason: reason))
      }
    }
  }
}

// ============================================================================
// HTTP
// ============================================================================

fn do_request(body: String, api_key: String) -> Result(String, String) {
  let assert Ok(req) = request.to(api_url)

  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("authorization", "Bearer " <> api_key)
    |> request.set_body(body)

  let _ = io.println("[minimax] Sending request body: " <> body)

  case hackney.send(req) {
    Ok(response) -> {
      let _ =
        io.println(
          "[minimax] Response status: " <> int.to_string(response.status),
        )
      let _ = io.println("[minimax] Response body: " <> response.body)
      case response.status {
        200 -> Ok(response.body)
        status ->
          Error("API error " <> string.inspect(status) <> ": " <> response.body)
      }
    }
    Error(err) -> {
      let _ = io.println("[minimax] Hackney error: " <> string.inspect(err))
      Error("Network error connecting to MiniMax")
    }
  }
}

// ============================================================================
// Response parsing
// ============================================================================

/// Parse a Minimax v2 response.
///
/// Minimax wraps the OpenAI-compatible payload with a `base_resp` field that
/// can signal errors even on HTTP 200 (e.g. content filter triggered).
/// We check `base_resp` first, then fall through to the standard OpenAI parser.
fn parse_response(
  json_str: String,
) -> Result(provider.ChatResponse, provider.LLMError) {
  case json.parse(json_str, base_resp_decoder()) {
    Ok(#(status_code, status_msg)) if status_code != 0 ->
      Error(provider.APIError(status: status_code, message: status_msg))
    _ -> check_sensitive(json_str)
  }
}

fn check_sensitive(
  json_str: String,
) -> Result(provider.ChatResponse, provider.LLMError) {
  case json.parse(json_str, sensitive_decoder()) {
    Ok(#(True, _)) ->
      Error(provider.APIError(
        status: 1002,
        message: "Request blocked by MiniMax input content filter",
      ))
    Ok(#(_, True)) ->
      Error(provider.APIError(
        status: 1003,
        message: "Response blocked by MiniMax output content filter",
      ))
    _ -> openai.parse_response(json_str)
  }
}

// ============================================================================
// Decoders
// ============================================================================

fn base_resp_decoder() -> decode.Decoder(#(Int, String)) {
  use base_resp <- decode.field("base_resp", {
    use status_code <- decode.field("status_code", decode.int)
    use status_msg <- decode.field("status_msg", decode.string)
    decode.success(#(status_code, status_msg))
  })
  decode.success(base_resp)
}

fn sensitive_decoder() -> decode.Decoder(#(Bool, Bool)) {
  use input_sensitive <- decode.optional_field(
    "input_sensitive",
    False,
    decode.bool,
  )
  use output_sensitive <- decode.optional_field(
    "output_sensitive",
    False,
    decode.bool,
  )
  decode.success(#(input_sensitive, output_sensitive))
}
