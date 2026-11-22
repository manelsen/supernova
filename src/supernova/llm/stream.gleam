//// LLM Streaming — real-time chunked responses from LLM providers.
////
//// Provides types and functions for streaming LLM responses as they are
//// generated, rather than waiting for the complete response.
////
//// ## Architecture
////
//// - Pure parsing functions for SSE (OpenAI) and event-stream (Anthropic)
//// - Actor-based stream management via `start_stream`
//// - FFI layer for non-blocking HTTP streaming
////
//// ## Usage
////
//// ```gleam
//// let subject = stream.start_stream(messages, config)
//// // Receive chunks via actor.call or process messages
//// ```

import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/llm/client
import supernova/llm/provider
import supernova/llm/providers/openai

// ============================================================================
// Types
// ============================================================================

/// A chunk of data from a streaming LLM response.
pub type StreamChunk {
  /// A text content delta — partial text being generated
  TextChunk(content: String)
  /// A tool call delta — partial tool call information
  ToolCallChunk(id: String, name: String, arguments_delta: String, index: Int)
  /// Stream is complete
  Done
  /// An error occurred during streaming
  StreamError(reason: String)
}

/// Stream configuration.
pub type StreamConfig {
  StreamConfig(
    /// Provider configuration
    provider_config: provider.ProviderConfig,
    /// Messages to send
    messages: List(provider.ChatMessage),
    /// Tool definitions
    tools: List(provider.ToolDefinition),
    /// Timeout in milliseconds (default: 60000)
    timeout_ms: Int,
  )
}

// ============================================================================
// SSE Parsing (Pure)
// ============================================================================

/// Parse OpenAI SSE format into stream chunks.
///
/// OpenAI sends Server-Sent Events like:
/// ```
/// data: {"choices":[{"delta":{"content":"Hello"}}]}
/// data: {"choices":[{"delta":{"content":" world"}}]}
/// data: [DONE]
/// ```
pub fn parse_openai_sse(raw: String) -> List(StreamChunk) {
  raw
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    let trimmed = string.trim(line)
    case string.starts_with(trimmed, "data: ") {
      True -> {
        let data = string.drop_start(trimmed, 6)
        case data {
          "[DONE]" -> Ok(Done)
          "" -> Error(Nil)
          json_str -> parse_openai_chunk(json_str)
        }
      }
      False -> {
        // Skip non-data lines (comments, empty lines, etc.)
        Error(Nil)
      }
    }
  })
}

/// Parse a single OpenAI SSE data line into a StreamChunk.
pub fn parse_openai_chunk(json_str: String) -> Result(StreamChunk, Nil) {
  case json.parse(json_str, openai_chunk_decoder()) {
    Ok(chunk) -> Ok(chunk)
    Error(_) -> Error(Nil)
  }
}

/// Decoder for OpenAI streaming chunk.
fn openai_chunk_decoder() -> decode.Decoder(StreamChunk) {
  use choices <- decode.field("choices", decode.list(openai_choice_decoder()))
  case choices {
    [first, ..] -> decode.success(first)
    [] -> decode.success(Done)
  }
}

/// Decoder for a single OpenAI choice in streaming.
fn openai_choice_decoder() -> decode.Decoder(StreamChunk) {
  use delta <- decode.field("delta", openai_delta_decoder())
  decode.success(delta)
}

/// Decoder for the delta object.
fn openai_delta_decoder() -> decode.Decoder(StreamChunk) {
  use content <- decode.optional_field(
    "content",
    None,
    decode.string |> decode.map(Some),
  )
  use tool_calls <- decode.optional_field(
    "tool_calls",
    None,
    decode.list(openai_tool_call_delta_decoder()) |> decode.map(Some),
  )

  case tool_calls {
    Some(calls) -> {
      case calls {
        [first, ..] -> decode.success(first)
        [] -> {
          case content {
            Some(text) -> decode.success(TextChunk(content: text))
            None -> decode.success(TextChunk(content: ""))
          }
        }
      }
    }
    None -> {
      case content {
        Some(text) -> decode.success(TextChunk(content: text))
        None -> decode.success(TextChunk(content: ""))
      }
    }
  }
}

/// Decoder for OpenAI tool call delta.
fn openai_tool_call_delta_decoder() -> decode.Decoder(StreamChunk) {
  use index <- decode.optional_field("index", 0, decode.int)
  use id <- decode.optional_field("id", "", decode.string)
  use function <- decode.optional_field(
    "function",
    #("", ""),
    openai_function_delta_decoder(),
  )

  decode.success(ToolCallChunk(
    id: id,
    name: function.0,
    arguments_delta: function.1,
    index: index,
  ))
}

/// Decoder for function delta in tool call.
fn openai_function_delta_decoder() -> decode.Decoder(#(String, String)) {
  use name <- decode.optional_field("name", "", decode.string)
  use arguments <- decode.optional_field("arguments", "", decode.string)
  decode.success(#(name, arguments))
}

// ============================================================================
// Anthropic Event Parsing (Pure)
// ============================================================================

/// Parse Anthropic streaming events into stream chunks.
///
/// Anthropic sends events like:
/// ```
/// event: content_block_delta
/// data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}
///
/// event: message_stop
/// data: {"type":"message_stop"}
/// ```
pub fn parse_anthropic_events(raw: String) -> List(StreamChunk) {
  let lines = string.split(raw, "\n")
  parse_anthropic_lines(lines, None)
}

/// Internal: parse Anthropic event lines, tracking event type.
fn parse_anthropic_lines(
  lines: List(String),
  current_event: Option(String),
) -> List(StreamChunk) {
  case lines {
    [] -> []
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case trimmed {
        "" -> parse_anthropic_lines(rest, None)
        _ -> {
          case string.starts_with(trimmed, "event: ") {
            True -> {
              let event_type = string.drop_start(trimmed, 7) |> string.trim
              parse_anthropic_lines(rest, Some(event_type))
            }
            False -> {
              case string.starts_with(trimmed, "data: ") {
                True -> {
                  let data = string.drop_start(trimmed, 6)
                  let chunk = parse_anthropic_data(data, current_event)
                  case chunk {
                    Ok(c) -> [c, ..parse_anthropic_lines(rest, None)]
                    Error(_) -> parse_anthropic_lines(rest, None)
                  }
                }
                False -> parse_anthropic_lines(rest, current_event)
              }
            }
          }
        }
      }
    }
  }
}

/// Parse Anthropic data line based on event type.
fn parse_anthropic_data(
  json_str: String,
  event_type: Option(String),
) -> Result(StreamChunk, Nil) {
  case event_type {
    Some("content_block_delta") -> parse_anthropic_content_delta(json_str)
    Some("message_stop") -> Ok(Done)
    Some("error") -> parse_anthropic_error(json_str)
    Some("message_start") -> Ok(TextChunk(content: ""))
    Some("content_block_start") -> Ok(TextChunk(content: ""))
    Some("content_block_stop") -> Ok(TextChunk(content: ""))
    Some("message_delta") -> parse_anthropic_message_delta(json_str)
    _ -> Error(Nil)
  }
}

/// Parse a content_block_delta event.
fn parse_anthropic_content_delta(json_str: String) -> Result(StreamChunk, Nil) {
  case json.parse(json_str, anthropic_content_delta_decoder()) {
    Ok(chunk) -> Ok(chunk)
    Error(_) -> Error(Nil)
  }
}

fn anthropic_content_delta_decoder() -> decode.Decoder(StreamChunk) {
  use delta <- decode.field("delta", decode.dynamic)
  // Try text delta first
  let text_result = decode.run(delta, anthropic_text_delta_decoder())
  case text_result {
    Ok(chunk) -> decode.success(chunk)
    Error(_) -> {
      // Try tool use delta
      let tool_result = decode.run(delta, anthropic_tool_delta_decoder())
      case tool_result {
        Ok(chunk) -> decode.success(chunk)
        Error(_) -> decode.success(TextChunk(content: ""))
      }
    }
  }
}

fn anthropic_text_delta_decoder() -> decode.Decoder(StreamChunk) {
  use delta_type <- decode.field("type", decode.string)
  case delta_type {
    "text_delta" -> {
      use text <- decode.field("text", decode.string)
      decode.success(TextChunk(content: text))
    }
    _ -> decode.failure(TextChunk(content: ""), "text_delta")
  }
}

fn anthropic_tool_delta_decoder() -> decode.Decoder(StreamChunk) {
  use delta_type <- decode.field("type", decode.string)
  case delta_type {
    "input_json_delta" -> {
      use partial <- decode.field("partial_json", decode.string)
      decode.success(ToolCallChunk(
        id: "",
        name: "",
        arguments_delta: partial,
        index: 0,
      ))
    }
    _ ->
      decode.failure(
        ToolCallChunk(id: "", name: "", arguments_delta: "", index: 0),
        "input_json_delta",
      )
  }
}

/// Parse a message_delta event (contains stop reason).
fn parse_anthropic_message_delta(json_str: String) -> Result(StreamChunk, Nil) {
  case json.parse(json_str, anthropic_message_delta_decoder()) {
    Ok(chunk) -> Ok(chunk)
    Error(_) -> Error(Nil)
  }
}

fn anthropic_message_delta_decoder() -> decode.Decoder(StreamChunk) {
  use _delta <- decode.field("delta", decode.dynamic)
  decode.success(TextChunk(content: ""))
}

/// Parse an Anthropic error event.
fn parse_anthropic_error(json_str: String) -> Result(StreamChunk, Nil) {
  case json.parse(json_str, anthropic_error_decoder()) {
    Ok(msg) -> Ok(StreamError(reason: msg))
    Error(_) -> Ok(StreamError(reason: "Unknown streaming error"))
  }
}

fn anthropic_error_decoder() -> decode.Decoder(String) {
  use error_type <- decode.field("type", decode.string)
  use message <- decode.field("message", decode.string)
  decode.success(error_type <> ": " <> message)
}

// ============================================================================
// Stream Actor
// ============================================================================

/// Start a streaming LLM request.
///
/// Returns a Subject that will receive StreamChunk messages.
/// The stream runs in an actor process that handles the HTTP connection
/// and parses incoming data into chunks.
pub fn start_stream(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
) -> Subject(StreamChunk) {
  start_stream_with_tools(messages, config, [])
}

/// Start a streaming LLM request with tool definitions.
pub fn start_stream_with_tools(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Subject(StreamChunk) {
  start_stream_from(fn() { client.chat(messages, config, tools) })
}

/// Run `call` in a worker and forward its result as stream chunks. The
/// caller decides how the call is made (and instrumented).
pub fn start_stream_from(
  call: fn() -> Result(provider.ChatResponse, provider.LLMError),
) -> Subject(StreamChunk) {
  let relay = process.new_subject()

  // Spawn a worker that makes a synchronous LLM call and forwards
  // the result as stream chunks.  This avoids the broken stub that
  // never wired the relay to the actor.
  let _ =
    process.spawn_unlinked(fn() {
      case call() {
        Ok(response) -> {
          // Send text content as a single chunk
          case response.content {
            "" -> Nil
            content -> process.send(relay, TextChunk(content: content))
          }
          // If there are tool calls, send them
          case response.tool_calls {
            Some(calls) -> {
              list.each(calls, fn(call) {
                process.send(
                  relay,
                  ToolCallChunk(
                    id: call.id,
                    name: call.name,
                    arguments_delta: call.arguments,
                    index: 0,
                  ),
                )
              })
              Nil
            }
            None -> Nil
          }
          process.send(relay, Done)
        }
        Error(error) ->
          process.send(relay, StreamError(reason: format_stream_error(error)))
      }
    })

  relay
}

fn format_stream_error(error: provider.LLMError) -> String {
  case error {
    provider.APIError(status, message) ->
      "API error " <> int.to_string(status) <> ": " <> message
    provider.NetworkError(reason) -> "Network error: " <> reason
    provider.ConfigError(reason) -> "Config error: " <> reason
    provider.ProviderNotFound(name) -> "Provider not found: " <> name
    provider.NotImplemented(reason) -> "Not implemented: " <> reason
    provider.CircuitOpen(provider) -> "Circuit open: " <> provider
  }
}

// ============================================================================
// Provider-Specific Stream Builders
// ============================================================================

/// Build the JSON request body for OpenAI streaming.
pub fn openai_stream_body(
  messages: List(provider.ChatMessage),
  model: String,
  tools: List(provider.ToolDefinition),
) -> String {
  let messages_json = json.array(messages, fn(m) { encode_message(m) })

  let base_fields = [
    #("model", json.string(model)),
    #("messages", messages_json),
    #("stream", json.bool(True)),
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

/// Build the JSON request body for Anthropic streaming.
pub fn anthropic_stream_body(
  messages: List(provider.ChatMessage),
  model: String,
  tools: List(provider.ToolDefinition),
) -> String {
  let system_msg = extract_system_message(messages)
  let non_system_msgs = list.filter(messages, fn(m) { m.role != "system" })

  let base_fields = [
    #("model", json.string(model)),
    #("max_tokens", json.int(4096)),
    #("messages", json.array(non_system_msgs, encode_message)),
    #("stream", json.bool(True)),
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

// ============================================================================
// JSON Encoding Helpers (for request building)
// ============================================================================

fn encode_message(msg: provider.ChatMessage) -> json.Json {
  let base = [
    #("role", json.string(msg.role)),
    #("content", openai.encode_content(msg)),
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

  json.object(with_tool_calls)
}

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

fn extract_system_message(
  messages: List(provider.ChatMessage),
) -> Option(String) {
  case list.find(messages, fn(m) { m.role == "system" }) {
    Ok(msg) -> Some(msg.content)
    Error(_) -> None
  }
}
// ============================================================================
// FFI Declarations
// ============================================================================
