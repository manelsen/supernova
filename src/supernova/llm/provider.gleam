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

import gleam/list
import gleam/option.{type Option, None, Some}

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
  )
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
  ToolDefinition(name: name, description: description, parameters: parameters)
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
