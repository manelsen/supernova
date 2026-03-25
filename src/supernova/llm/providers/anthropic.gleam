//// Anthropic Provider — chat completion via Anthropic Messages API.
////
//// Implements request building and response parsing for the Anthropic
//// Messages API (not the legacy completions API).
////
//// ## Usage
////
//// ```gleam
//// let config = provider.ProviderConfig(name: "anthropic", api_key: Some("sk-ant-..."), ...)
//// let result = anthropic.chat(messages, config, tools)
//// ```

import gleam/dynamic/decode
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/llm/provider

// ============================================================================
// Constants
// ============================================================================

const api_url = "https://api.anthropic.com/v1/messages"

// ============================================================================
// Public API
// ============================================================================

/// Send a chat completion request to Anthropic.
pub fn chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  let body = build_request_body(messages, config.default_model, tools)

  case config.api_key {
    Some(api_key) -> {
      case do_request(body, api_key) {
        Ok(response_body) -> parse_response(response_body)
        Error(reason) -> Error(provider.NetworkError(reason: reason))
      }
    }
    None ->
      Error(provider.ConfigError(reason: "No API key configured for Anthropic"))
  }
}

/// Build the JSON request body for Anthropic Messages API.
///
/// Exported for testing.
pub fn build_request_body(
  messages: List(provider.ChatMessage),
  model: String,
  tools: List(provider.ToolDefinition),
) -> String {
  // Anthropic requires system message to be separate
  let system_msg = extract_system_message(messages)
  let non_system_msgs = list.filter(messages, fn(m) { m.role != "system" })

  let base_fields = [
    #("model", json.string(model)),
    #("max_tokens", json.int(4096)),
    #("messages", json.array(non_system_msgs, encode_message)),
  ]

  let with_system = case system_msg {
    Some(content) ->
      list.append(base_fields, [#("system", json.string(content))])
    None -> base_fields
  }

  let fields = case tools {
    [] -> with_system
    _ ->
      list.append(with_system, [
        #("tools", json.array(tools, encode_tool)),
      ])
  }

  json.object(fields)
  |> json.to_string
}

/// Parse an Anthropic API response JSON string.
///
/// Exported for testing.
pub fn parse_response(
  json_str: String,
) -> Result(provider.ChatResponse, provider.LLMError) {
  case json.parse(json_str, response_decoder()) {
    Ok(response) -> Ok(response)
    Error(_) -> {
      case json.parse(json_str, error_decoder()) {
        Ok(error_msg) ->
          Error(provider.APIError(status: 400, message: error_msg))
        Error(_) ->
          Error(provider.APIError(
            status: 0,
            message: "Failed to parse response",
          ))
      }
    }
  }
}

// ============================================================================
// Internal
// ============================================================================

/// Extract system message content from messages.
fn extract_system_message(
  messages: List(provider.ChatMessage),
) -> Option(String) {
  case list.find(messages, fn(m) { m.role == "system" }) {
    Ok(msg) -> Some(msg.content)
    Error(_) -> None
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
    |> request.set_header("x-api-key", api_key)
    |> request.set_header("anthropic-version", "2023-06-01")
    |> request.set_body(body)

  case hackney.send(req) {
    Ok(response) -> {
      case response.status {
        200 -> Ok(response.body)
        status ->
          Error(
            "Anthropic API error: "
            <> string.inspect(status)
            <> " - "
            <> response.body,
          )
      }
    }
    Error(_) -> Error("Network error connecting to Anthropic")
  }
}

// ============================================================================
// JSON Encoders
// ============================================================================

fn encode_message(msg: provider.ChatMessage) -> json.Json {
  let base = [
    #("role", json.string(msg.role)),
    #("content", json.string(msg.content)),
  ]
  json.object(base)
}

fn encode_tool(tool: provider.ToolDefinition) -> json.Json {
  let properties =
    tool.parameters
    |> list.map(fn(p) {
      #(
        p.name,
        json.object([
          #("type", json.string(p.param_type)),
          #("description", json.string(p.description)),
        ]),
      )
    })

  let required =
    tool.parameters
    |> list.filter(fn(p) { p.required })
    |> list.map(fn(p) { json.string(p.name) })

  json.object([
    #("name", json.string(tool.name)),
    #("description", json.string(tool.description)),
    #(
      "input_schema",
      json.object([
        #("type", json.string("object")),
        #("properties", json.object(properties)),
        #("required", json.array(required, fn(x) { x })),
      ]),
    ),
  ])
}

// ============================================================================
// JSON Decoders
// ============================================================================

fn response_decoder() -> decode.Decoder(provider.ChatResponse) {
  use content_blocks <- decode.field(
    "content",
    decode.list(content_block_decoder()),
  )
  case content_blocks {
    [first, ..] -> decode.success(first)
    [] ->
      decode.failure(
        provider.ChatResponse(
          role: "assistant",
          content: "",
          tool_calls: None,
          reasoning_content: None,
        ),
        "content",
      )
  }
}

fn content_block_decoder() -> decode.Decoder(provider.ChatResponse) {
  use block_type <- decode.field("type", decode.string)
  case block_type {
    "text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(provider.ChatResponse(
        role: "assistant",
        content: text,
        tool_calls: None,
        reasoning_content: None,
      ))
    }
    "tool_use" -> {
      use id <- decode.field("id", decode.string)
      use name <- decode.field("name", decode.string)
      use input <- decode.field("input", decode.string)
      decode.success(provider.ChatResponse(
        role: "assistant",
        content: "",
        tool_calls: Some([
          provider.ToolCall(id: id, name: name, arguments: input),
        ]),
        reasoning_content: None,
      ))
    }
    _ ->
      decode.failure(
        provider.ChatResponse(
          role: "assistant",
          content: "",
          tool_calls: None,
          reasoning_content: None,
        ),
        "type",
      )
  }
}

fn error_decoder() -> decode.Decoder(String) {
  use error_obj <- decode.field("error", error_message_decoder())
  decode.success(error_obj)
}

fn error_message_decoder() -> decode.Decoder(String) {
  use message <- decode.field("message", decode.string)
  decode.success(message)
}
