//// LLM Provider — types and builders for LLM interactions.
////
//// Defines the core types used across all LLM providers:
//// messages, tool definitions, tool calls, responses, and configuration.
////
//// ## Usage
////
//// ```gleam
//// let msg = provider.user_message("Hello!")
//// let tool = provider.new_tool(name: "get_weather", description: "...", parameters: [...])
//// ```

import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// ============================================================================
// Types
// ============================================================================

/// A chat message.
pub type ChatMessage {
  ChatMessage(
    /// Message role: "system", "user", "assistant", "tool"
    role: String,
    /// Message content
    content: String,
    /// Tool call ID (for tool result messages)
    tool_call_id: Option(String),
    /// Tool calls made by assistant (if any)
    tool_calls: Option(List(ToolCall)),
    /// Reasoning / thinking content produced by the model (e.g. Zhipu GLM-4.7).
    /// Must be echoed back verbatim in subsequent requests when present.
    reasoning_content: Option(String),
    /// Images attached to the message, as data URLs
    /// (`data:image/jpeg;base64,...`). Only user messages carry them; providers
    /// that cannot send images ignore them.
    images: List(String),
  )
}

/// A tool call made by the LLM.
pub type ToolCall {
  ToolCall(
    /// Unique ID for this tool call
    id: String,
    /// Name of the tool to call
    name: String,
    /// JSON-encoded arguments
    arguments: String,
  )
}

/// A tool parameter definition.
pub type ToolParam {
  ToolParam(
    /// Parameter type: "string", "integer", "number", "boolean"
    param_type: String,
    /// Parameter name
    name: String,
    /// Parameter description
    description: String,
    /// Whether this parameter is required
    required: Bool,
  )
}

/// A tool definition for the LLM.
pub type ToolDefinition {
  ToolDefinition(
    /// Tool name
    name: String,
    /// Tool description
    description: String,
    /// Tool parameters
    parameters: List(ToolParam),
    /// A full JSON Schema for the arguments, as JSON text, when the flat
    /// parameters cannot say it (arrays, objects): the tools of an MCP
    /// server (PRD-S, S-01). Used instead of `parameters` when present.
    schema: Option(String),
  )
}

/// Provider configuration.
pub type ProviderConfig {
  ProviderConfig(
    /// Provider name (e.g., "openai", "anthropic", "mock")
    name: String,
    /// API key
    api_key: Option(String),
    /// Base URL override
    base_url: Option(String),
    /// Default model
    default_model: String,
  )
}

/// A chat response from the LLM.
pub type ChatResponse {
  ChatResponse(
    /// Response role (always "assistant")
    role: String,
    /// Response content (may be empty if tool calls)
    content: String,
    /// Tool calls requested by the LLM
    tool_calls: Option(List(ToolCall)),
    /// Reasoning / thinking content (e.g. Zhipu GLM-4.7 thinking mode).
    /// Pass this back as `reasoning_content` in the next assistant message.
    reasoning_content: Option(String),
  )
}

/// LLM error types.
pub type LLMError {
  /// API returned an error
  APIError(status: Int, message: String)
  /// Network error
  NetworkError(reason: String)
  /// Invalid configuration
  ConfigError(reason: String)
  /// Provider not found
  ProviderNotFound(name: String)
  /// Feature not yet implemented in this adapter
  NotImplemented(reason: String)
  /// Circuit breaker is open for this provider
  CircuitOpen(provider: String)
}

// ============================================================================
// Message Builders
// ============================================================================

/// Create a user message.
pub fn user_message(content: String) -> ChatMessage {
  ChatMessage(
    role: "user",
    content: content,
    tool_call_id: None,
    tool_calls: None,
    reasoning_content: None,
    images: [],
  )
}

/// Create a system message.
pub fn system_message(content: String) -> ChatMessage {
  ChatMessage(
    role: "system",
    content: content,
    tool_call_id: None,
    tool_calls: None,
    reasoning_content: None,
    images: [],
  )
}

/// Create an assistant message.
pub fn assistant_message(content: String) -> ChatMessage {
  ChatMessage(
    role: "assistant",
    content: content,
    tool_call_id: None,
    tool_calls: None,
    reasoning_content: None,
    images: [],
  )
}

/// Create an assistant message with tool calls.
pub fn assistant_message_with_tools(
  content: String,
  tool_calls: List(ToolCall),
) -> ChatMessage {
  ChatMessage(
    role: "assistant",
    content: content,
    tool_call_id: None,
    tool_calls: Some(tool_calls),
    reasoning_content: None,
    images: [],
  )
}

/// Create a tool result message.
pub fn tool_result_message(
  tool_call_id: String,
  content: String,
) -> ChatMessage {
  ChatMessage(
    role: "tool",
    content: content,
    tool_call_id: Some(tool_call_id),
    tool_calls: None,
    reasoning_content: None,
    images: [],
  )
}

/// Create a user message that carries images (data URLs) next to its text.
pub fn user_message_with_images(
  content: String,
  images: List(String),
) -> ChatMessage {
  ChatMessage(..user_message(content), images: images)
}

// ============================================================================
// Tool Builders
// ============================================================================

/// Create a new tool definition.
pub fn new_tool(
  name name: String,
  description description: String,
  parameters parameters: List(ToolParam),
) -> ToolDefinition {
  ToolDefinition(
    name: name,
    description: description,
    parameters: parameters,
    schema: None,
  )
}

/// A tool whose arguments are described by a full JSON Schema (`schema`
/// is its JSON text).
pub fn tool_with_schema(
  name name: String,
  description description: String,
  schema schema: String,
) -> ToolDefinition {
  ToolDefinition(
    name: name,
    description: description,
    parameters: [],
    schema: Some(schema),
  )
}

/// The JSON Schema of a tool's arguments, as every provider sends it: the
/// full schema when the tool has one that parses, else the flat
/// parameters as an object schema.
pub fn parameters_schema(tool: ToolDefinition) -> json.Json {
  let full = case tool.schema {
    Some(text) ->
      case json.parse(text, decode.dynamic) {
        Ok(value) ->
          case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
            Ok(_) -> Ok(dynamic_json(value))
            Error(_) -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    None -> Error(Nil)
  }
  case full {
    Ok(schema) -> schema
    Error(Nil) -> {
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
        #("type", json.string("object")),
        #("properties", json.object(properties)),
        #("required", json.array(required, fn(x) { x })),
      ])
    }
  }
}

/// A decoded JSON value back to JSON.
pub fn dynamic_json(value: dynamic.Dynamic) -> json.Json {
  let attempts = [
    decode.bool |> decode.map(json.bool),
    decode.int |> decode.map(json.int),
    decode.float |> decode.map(json.float),
    decode.string |> decode.map(json.string),
    decode.list(decode.dynamic)
      |> decode.map(fn(items) { json.array(items, dynamic_json) }),
    decode.dict(decode.string, decode.dynamic)
      |> decode.map(fn(entries) {
        dict.to_list(entries)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.map(fn(entry) { #(entry.0, dynamic_json(entry.1)) })
        |> json.object
      }),
  ]
  first_decoded(value, attempts)
}

fn first_decoded(
  value: dynamic.Dynamic,
  attempts: List(decode.Decoder(json.Json)),
) -> json.Json {
  case attempts {
    [] -> json.null()
    [attempt, ..rest] ->
      case decode.run(value, attempt) {
        Ok(encoded) -> encoded
        Error(_) -> first_decoded(value, rest)
      }
  }
}

/// Create a string parameter.
pub fn string_param(
  name: String,
  description: String,
  required: Bool,
) -> ToolParam {
  ToolParam(
    param_type: "string",
    name: name,
    description: description,
    required: required,
  )
}

/// Create an integer parameter.
pub fn integer_param(
  name: String,
  description: String,
  required: Bool,
) -> ToolParam {
  ToolParam(
    param_type: "integer",
    name: name,
    description: description,
    required: required,
  )
}

/// Create a boolean parameter.
pub fn boolean_param(
  name: String,
  description: String,
  required: Bool,
) -> ToolParam {
  ToolParam(
    param_type: "boolean",
    name: name,
    description: description,
    required: required,
  )
}

/// Get required parameters from a tool definition.
pub fn required_params(tool: ToolDefinition) -> List(ToolParam) {
  list.filter(tool.parameters, fn(p) { p.required })
}
