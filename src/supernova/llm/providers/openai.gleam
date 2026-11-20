//// OpenAI Provider — chat completion via OpenAI API.
////
//// Implements request building, response parsing, and HTTP calls
//// for the OpenAI chat completions API.
////
//// ## Usage
////
//// ```gleam
//// let config = provider.ProviderConfig(name: "openai", api_key: Some("sk-..."), ...)
//// let result = openai.chat(messages, config, tools)
//// ```

import gleam/dynamic/decode
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import supernova/llm/provider

// ============================================================================
// Constants
// ============================================================================

const api_url = "https://api.openai.com/v1/chat/completions"

// ============================================================================
// Public API
// ============================================================================

/// Send a chat completion request to OpenAI.
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
      Error(provider.ConfigError(reason: "No API key configured for OpenAI"))
  }
}

/// Build the JSON request body for OpenAI chat completion.
///
/// Exported for testing.
pub fn build_request_body(
  messages: List(provider.ChatMessage),
  model: String,
  tools: List(provider.ToolDefinition),
) -> String {
  let messages_json = json.array(messages, fn(m) { encode_message(m) })

  let base_fields = [
    #("model", json.string(model)),
    #("messages", messages_json),
  ]

  let fields = case tools {
    [] -> base_fields
    _ ->
      list.append(base_fields, [
        #("tools", json.array(tools, fn(t) { encode_tool(t) })),
      ])
  }

  json.object(fields)
  |> json.to_string
}

/// Parse an OpenAI API response JSON string.
///
/// Exported for testing.
pub fn parse_response(
  json_str: String,
) -> Result(provider.ChatResponse, provider.LLMError) {
  case json.parse(json_str, response_decoder()) {
    Ok(response) -> Ok(response)
    Error(_) -> {
      // Try to parse as error
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
// HTTP
// ============================================================================

/// Make the HTTP POST request to OpenAI.
fn do_request(body: String, api_key: String) -> Result(String, String) {
  let assert Ok(req) = request.to(api_url)

  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("authorization", "Bearer " <> api_key)
    |> request.set_body(body)

  case hackney.send(req) {
    Ok(response) -> {
      case response.status {
        200 -> Ok(response.body)
        status ->
          Error(
            "OpenAI API error: "
            <> string.inspect(status)
            <> " - "
            <> response.body,
          )
      }
    }
    Error(_) -> Error("Network error connecting to OpenAI")
  }
}

// ============================================================================
// JSON Encoders
// ============================================================================

/// Encode a ChatMessage to JSON.
fn encode_message(msg: provider.ChatMessage) -> json.Json {
  let base = [
    #("role", json.string(msg.role)),
    #("content", json.string(msg.content)),
  ]

  let with_tool_call_id = case msg.tool_call_id {
    Some(id) -> list.append(base, [#("tool_call_id", json.string(id))])
    None -> base
  }

  let with_tool_calls = case msg.tool_calls {
    Some(calls) ->
      list.append(with_tool_call_id, [
        #("tool_calls", json.array(calls, encode_tool_call)),
      ])
    None -> with_tool_call_id
  }

  // Zhipu GLM-4.7: reasoning_content must be echoed back verbatim in the
  // assistant message that preceded a tool call, or the API returns 400.
  let with_reasoning = case msg.reasoning_content {
    Some(rc) ->
      list.append(with_tool_calls, [#("reasoning_content", json.string(rc))])
    None -> with_tool_calls
  }

  json.object(with_reasoning)
}

/// Encode a ToolCall to JSON.
fn encode_tool_call(tc: provider.ToolCall) -> json.Json {
  json.object([
    #("id", json.string(tc.id)),
    #("type", json.string("function")),
    #(
      "function",
      json.object([
        #("name", json.string(tc.name)),
        #("arguments", json.string(tc.arguments)),
      ]),
    ),
  ])
}

/// Encode a ToolDefinition to JSON.
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
    #("type", json.string("function")),
    #(
      "function",
      json.object([
        #("name", json.string(tool.name)),
        #("description", json.string(tool.description)),
        #(
          "parameters",
          json.object([
            #("type", json.string("object")),
            #("properties", json.object(properties)),
            #("required", json.array(required, fn(x) { x })),
          ]),
        ),
      ]),
    ),
  ])
}

// ============================================================================
// JSON Decoders
// ============================================================================

/// Decode a ChatResponse from JSON.
fn response_decoder() -> decode.Decoder(provider.ChatResponse) {
  use choices <- decode.field("choices", decode.list(choice_decoder()))
  case choices {
    [first, ..] -> decode.success(first)
    [] ->
      decode.failure(
        provider.ChatResponse(
          role: "assistant",
          content: "",
          tool_calls: None,
          reasoning_content: None,
        ),
        "choices",
      )
  }
}

/// Decode a single choice.
fn choice_decoder() -> decode.Decoder(provider.ChatResponse) {
  use message <- decode.field("message", message_decoder())
  decode.success(message)
}

/// Decode the message object.
fn message_decoder() -> decode.Decoder(provider.ChatResponse) {
  use role <- decode.field("role", decode.string)
  // Each field may be missing or explicitly null: Mistral sends
  // "tool_calls": null on a plain answer, which failed every agent turn.
  use content <- decode.optional_field(
    "content",
    None,
    decode.optional(decode.string),
  )
  use tool_calls <- decode.optional_field(
    "tool_calls",
    None,
    decode.optional(decode.list(tool_call_decoder())),
  )
  use reasoning_content <- decode.optional_field(
    "reasoning_content",
    None,
    decode.optional(decode.string),
  )

  decode.success(provider.ChatResponse(
    role: role,
    content: option.unwrap(content, ""),
    tool_calls: tool_calls,
    reasoning_content: reasoning_content,
  ))
}

/// Decode a tool call from the response.
fn tool_call_decoder() -> decode.Decoder(provider.ToolCall) {
  use id <- decode.field("id", decode.string)
  use function <- decode.field("function", function_decoder())
  decode.success(provider.ToolCall(
    id: id,
    name: function.0,
    arguments: function.1,
  ))
}

/// Decode the function object inside a tool call.
fn function_decoder() -> decode.Decoder(#(String, String)) {
  use name <- decode.field("name", decode.string)
  use arguments <- decode.field("arguments", decode.string)
  decode.success(#(name, arguments))
}

/// Decode an error message.
fn error_decoder() -> decode.Decoder(String) {
  use error_obj <- decode.field("error", error_message_decoder())
  decode.success(error_obj)
}

/// Decode the error object.
fn error_message_decoder() -> decode.Decoder(String) {
  use message <- decode.field("message", decode.string)
  decode.success(message)
}
