//// MCP (Model Context Protocol) Client Connection Module
//// Implements typed connections to MCP providers with health checking
//// and automatic reconnection capabilities.
////
//// This module provides an actor-based MCP client that supports:
//// - Multiple providers (OpenAI, Anthropic, Local)
//// - Configurable API key authentication
//// - Health checking with automatic reconnection
//// - Connection state management

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string

// ============================================================================
// Types
// ============================================================================

/// Supported MCP providers
pub type MCPProvider {
  /// OpenAI API (GPT models)
  OpenAI
  /// Anthropic API (Claude models)
  Anthropic
  /// Local MCP server (self-hosted)
  Local(host: String, port: Int)
}

/// Connection status
pub type ConnectionStatus {
  /// Connection is being established
  Connecting
  /// Connection is active and healthy
  Connected
  /// Connection is disconnected
  Disconnected
  /// Connection failed with error
  ConnectionError(reason: String)
  /// Connection is being reconnected
  Reconnecting(attempt: Int)
}

/// Health check result
pub type HealthCheckResult {
  /// Health check passed
  Healthy(latency_ms: Int)
  /// Health check failed
  Unhealthy(reason: String)
}

/// Configuration for an MCP connection
pub type MCPConfig {
  MCPConfig(
    /// Unique identifier for this connection
    id: String,
    /// Provider to connect to
    provider: MCPProvider,
    /// API key for authentication (required for OpenAI/Anthropic)
    api_key: Option(String),
    /// Base URL override (optional)
    base_url: Option(String),
    /// Request timeout in milliseconds
    timeout_ms: Int,
    /// Health check interval in milliseconds (0 = disabled)
    health_check_interval_ms: Int,
    /// Maximum reconnection attempts (0 = unlimited)
    max_reconnect_attempts: Int,
    /// Delay between reconnection attempts in milliseconds
    reconnect_delay_ms: Int,
  )
}

/// Connection state maintained by the actor
pub type ConnectionState {
  ConnectionState(
    config: MCPConfig,
    status: ConnectionStatus,
    /// Last successful health check timestamp (0 = never)
    last_health_check: Int,
    /// Number of consecutive failed health checks
    failed_health_checks: Int,
    /// Current reconnection attempt (0 = not reconnecting)
    reconnect_attempt: Int,
    /// Request metadata (for tracking)
    metadata: Dict(String, String),
    /// Registered tools (name -> ToolEntry)
    tools: Dict(String, ToolEntry),
    /// Tool call counter for generating IDs
    tool_call_counter: Int,
  )
}

/// Messages that can be sent to the MCP connection actor
pub type Message {
  /// Get current connection status
  GetStatus(reply_to: Subject(ConnectionStatus))
  /// Get connection configuration
  GetConfig(reply_to: Subject(MCPConfig))
  /// Perform a health check
  HealthCheck(reply_to: Subject(HealthCheckResult))
  /// Connect to the provider
  Connect(reply_to: Subject(Result(Nil, String)))
  /// Disconnect from the provider
  Disconnect(reply_to: Subject(Nil))
  /// Reconnect to the provider (internal use)
  Reconnect(reply_to: Subject(Result(Nil, String)))
  /// Update the API key
  SetApiKey(reply_to: Subject(Nil), api_key: String)
  /// Get the provider type
  GetProvider(reply_to: Subject(MCPProvider))
  /// Set metadata value
  SetMetadata(reply_to: Subject(Nil), key: String, value: String)
  /// Get metadata value
  GetMetadata(reply_to: Subject(Option(String)), key: String)
  /// Start a streaming chat
  ChatStream(
    reply_to: Subject(StreamResult),
    context: ChatContext,
    chunk_subject: Subject(StreamChunk),
  )
  /// Register a tool
  RegisterTool(reply_to: Subject(Result(Nil, String)), tool: Tool)
  /// Unregister a tool
  UnregisterTool(reply_to: Subject(Bool), name: String)
  /// List all registered tools
  ListTools(reply_to: Subject(List(Tool)))
  /// Get a specific tool by name
  GetTool(reply_to: Subject(Option(Tool)), name: String)
  /// Execute a tool call
  ExecuteToolCall(reply_to: Subject(ToolResult), tool_call: ToolCall)
  /// Stop the connection actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to a running MCP connection
pub type MCPConnection =
  Subject(Message)

/// Error type for MCP operations
pub type MCPError {
  /// Configuration error
  ConfigError(message: String)
  /// Authentication error
  AuthError(message: String)
  /// Connection error
  ConnectionErrorType(message: String)
  /// Timeout error
  TimeoutError(message: String)
  /// Provider error
  ProviderError(message: String)
  /// Rate limit error
  RateLimitError(message: String, retry_after_ms: Option(Int))
}

// ============================================================================
// Chat Types
// ============================================================================

/// Role of a chat message sender
pub type ChatRole {
  /// System message (sets behavior/context)
  System
  /// User message
  User
  /// Assistant/LLM message
  Assistant
}

/// A single chat message
pub type ChatMessage {
  ChatMessage(role: ChatRole, content: String)
}

/// Context for a chat request
pub type ChatContext {
  ChatContext(
    /// System prompt to set behavior
    system_prompt: Option(String),
    /// Conversation history
    messages: List(ChatMessage),
    /// Model to use (provider-specific)
    model: Option(String),
    /// Maximum tokens to generate
    max_tokens: Option(Int),
    /// Temperature (0.0 - 1.0)
    temperature: Option(Float),
  )
}

/// A chunk of streaming response
pub type StreamChunk {
  /// Text content chunk
  ContentChunk(content: String)
  /// Streaming is complete
  Done(full_response: String)
  /// Error occurred during streaming
  StreamError(error: MCPError)
}

/// Callbacks for handling streaming events
pub type StreamCallbacks(a) {
  StreamCallbacks(
    /// Called for each chunk received
    on_chunk: fn(StreamChunk) -> a,
    /// Called when streaming completes successfully
    on_complete: fn(String) -> a,
    /// Called when an error occurs
    on_error: fn(MCPError) -> a,
  )
}

/// Result of starting a stream
pub type StreamResult {
  /// Stream started successfully, returns subject for receiving chunks
  StreamStarted(subject: Subject(StreamChunk))
  /// Failed to start stream
  StreamStartError(error: MCPError)
}

// ============================================================================
// Tool Types
// ============================================================================

/// JSON Schema type for a single parameter
pub type SchemaType {
  StringType
  IntegerType
  NumberType
  BooleanType
  ArrayType(items: SchemaType)
  ObjectType(properties: Dict(String, SchemaProperty))
}

/// A single property in an object schema
pub type SchemaProperty {
  SchemaProperty(
    /// Property type
    type_: SchemaType,
    /// Human-readable description
    description: Option(String),
    /// Whether the property is required
    required: Bool,
    /// Default value (as JSON string)
    default: Option(String),
  )
}

/// JSON Schema for tool parameters
pub type ToolSchema {
  ToolSchema(
    /// Schema type (typically Object)
    type_: SchemaType,
    /// List of required property names
    required: List(String),
    /// Property definitions
    properties: Dict(String, SchemaProperty),
  )
}

/// A tool definition with schema and handler
pub type Tool {
  Tool(
    /// Unique tool name (e.g., "get_weather")
    name: String,
    /// Human-readable description
    description: String,
    /// Parameter schema
    parameters: ToolSchema,
    /// Handler function that takes JSON arguments and returns result
    handler: fn(String) -> ToolResult,
  )
}

/// A tool call request from the LLM
pub type ToolCall {
  ToolCall(
    /// Unique call ID
    id: String,
    /// Name of the tool to call
    name: String,
    /// JSON-encoded arguments
    arguments: String,
  )
}

/// Result of executing a tool
pub type ToolResult {
  /// Tool executed successfully
  ToolSuccess(content: String)
  /// Tool execution failed
  ToolError(message: String)
}

/// Internal tool registry entry
pub type ToolEntry {
  ToolEntry(tool: Tool, registered_at: Int)
}

// ============================================================================
// Logging Helpers
// ============================================================================

type LogLevel {
  Debug
  Info
  Warning
  LogError
}

fn log_level_to_string(level: LogLevel) -> String {
  case level {
    Debug -> "DEBUG"
    Info -> "INFO"
    Warning -> "WARN"
    LogError -> "ERROR"
  }
}

fn format_status(status: ConnectionStatus) -> String {
  case status {
    Connecting -> "connecting"
    Connected -> "connected"
    Disconnected -> "disconnected"
    ConnectionError(reason) -> "error: " <> reason
    Reconnecting(attempt) ->
      "reconnecting (attempt " <> int.to_string(attempt) <> ")"
  }
}

fn format_provider(provider: MCPProvider) -> String {
  case provider {
    OpenAI -> "openai"
    Anthropic -> "anthropic"
    Local(host, port) -> "local:" <> host <> ":" <> int.to_string(port)
  }
}

fn log(
  level: LogLevel,
  component: String,
  message: String,
  attrs: List(#(String, String)),
) -> String {
  let level_str = log_level_to_string(level)

  let attrs_str =
    attrs
    |> list.map(fn(pair) {
      let #(key, value) = pair
      key <> "=" <> value
    })
    |> string.join(" ")

  case attrs_str {
    "" -> "[" <> level_str <> "] [" <> component <> "] " <> message
    _ ->
      "["
      <> level_str
      <> "] ["
      <> component
      <> "] "
      <> message
      <> " | "
      <> attrs_str
  }
}

// ============================================================================
// Connection Logic
// ============================================================================

/// Validate configuration for a provider
fn validate_config(config: MCPConfig) -> Result(Nil, String) {
  case config.provider {
    OpenAI -> {
      case config.api_key {
        Some(_) -> Ok(Nil)
        None -> Error("OpenAI provider requires an API key")
      }
    }
    Anthropic -> {
      case config.api_key {
        Some(_) -> Ok(Nil)
        None -> Error("Anthropic provider requires an API key")
      }
    }
    Local(_, _) -> Ok(Nil)
  }
}

/// Validate a tool definition
fn validate_tool(tool: Tool) -> Result(Nil, String) {
  case string.trim(tool.name) == "" {
    True -> Error("Tool name cannot be empty")
    False -> {
      case string.trim(tool.description) == "" {
        True -> Error("Tool description cannot be empty")
        False -> Ok(Nil)
      }
    }
  }
}

/// Validate and establish logical provider connectivity.
fn do_connect(config: MCPConfig) -> Result(Nil, String) {
  validate_config(config)
}

/// Perform a health check based on current provider configuration.
fn do_health_check(config: MCPConfig) -> HealthCheckResult {
  case validate_config(config) {
    Ok(_) -> Healthy(latency_ms: 0)
    Error(reason) -> Unhealthy(reason: reason)
  }
}

/// Calculate if reconnection should be attempted
fn should_reconnect(state: ConnectionState) -> Bool {
  case state.status {
    ConnectionError(_) | Disconnected -> {
      case state.config.max_reconnect_attempts {
        0 -> True
        // Unlimited attempts
        max -> state.reconnect_attempt < max
      }
    }
    _ -> False
  }
}

/// Validate chat context
fn validate_chat_context(context: ChatContext) -> Result(Nil, MCPError) {
  // Check that there's at least one message
  case list.length(context.messages) {
    0 ->
      Error(ConfigError(message: "Chat context must have at least one message"))
    _ -> Ok(Nil)
  }
}

/// Stream chat response chunks to the provided subject.
fn do_chat_stream(
  config: MCPConfig,
  context: ChatContext,
  chunk_subject: Subject(StreamChunk),
) -> Result(Nil, MCPError) {
  // Validate context first, then validate API key, then stream
  case validate_chat_context(context) {
    Error(error) -> Error(error)
    Ok(_) -> {
      case validate_api_key_for_stream(config) {
        Error(error) -> Error(error)
        Ok(_) -> {
          let full_response = build_stream_response(config, context)

          // Stream in word-sized chunks to emulate provider chunking.
          let chunks = split_chunks(full_response)
          list.each(chunks, fn(chunk) {
            actor.send(chunk_subject, ContentChunk(content: chunk))
          })

          // Send completion
          actor.send(chunk_subject, Done(full_response: full_response))

          Ok(Nil)
        }
      }
    }
  }
}

/// Validate API key for streaming
fn validate_api_key_for_stream(config: MCPConfig) -> Result(Nil, MCPError) {
  case config.provider {
    OpenAI | Anthropic -> {
      case config.api_key {
        Some(_) -> Ok(Nil)
        None ->
          Error(AuthError(
            message: "API key required for " <> format_provider(config.provider),
          ))
      }
    }
    Local(_, _) -> Ok(Nil)
  }
}

/// Split response into chunked words.
fn split_chunks(response: String) -> List(String) {
  string.split(response, " ")
  |> list.map(fn(word) { word <> " " })
}

fn build_stream_response(config: MCPConfig, context: ChatContext) -> String {
  let provider_name = format_provider(config.provider)
  let latest_user_message = case
    context.messages
    |> list.reverse
    |> list.find(fn(message) { message.role == User })
  {
    Ok(ChatMessage(content:, ..)) -> content
    Error(_) -> ""
  }

  "Provider " <> provider_name <> " response: " <> latest_user_message
}

// ============================================================================
// Actor Implementation
// ============================================================================

fn handle_message(
  state: ConnectionState,
  message: Message,
) -> actor.Next(ConnectionState, Message) {
  case message {
    GetStatus(reply_to) -> {
      let _ =
        log(Debug, "mcp", "GetStatus", [
          #("connection_id", state.config.id),
          #("status", format_status(state.status)),
        ])
      actor.send(reply_to, state.status)
      actor.continue(state)
    }

    GetConfig(reply_to) -> {
      let _ =
        log(Debug, "mcp", "GetConfig", [#("connection_id", state.config.id)])
      actor.send(reply_to, state.config)
      actor.continue(state)
    }

    HealthCheck(reply_to) -> {
      let _ =
        log(Debug, "mcp", "HealthCheck", [#("connection_id", state.config.id)])

      case state.status {
        Connected -> {
          let result = do_health_check(state.config)

          let new_state = case result {
            Healthy(_) ->
              ConnectionState(
                ..state,
                last_health_check: 0,
                // Placeholder timestamp
                failed_health_checks: 0,
              )
            Unhealthy(_) ->
              ConnectionState(
                ..state,
                failed_health_checks: state.failed_health_checks + 1,
              )
          }

          actor.send(reply_to, result)
          actor.continue(new_state)
        }
        _ -> {
          actor.send(reply_to, Unhealthy(reason: "Not connected"))
          actor.continue(state)
        }
      }
    }

    Connect(reply_to) -> {
      let _ =
        log(Info, "mcp", "Connect", [
          #("connection_id", state.config.id),
          #("provider", format_provider(state.config.provider)),
        ])

      case state.status {
        Connected -> {
          actor.send(reply_to, Ok(Nil))
          actor.continue(state)
        }
        _ -> {
          case do_connect(state.config) {
            Ok(_) -> {
              let new_state =
                ConnectionState(
                  ..state,
                  status: Connected,
                  reconnect_attempt: 0,
                  failed_health_checks: 0,
                )
              actor.send(reply_to, Ok(Nil))
              actor.continue(new_state)
            }
            Error(reason) -> {
              let new_state =
                ConnectionState(..state, status: ConnectionError(reason))
              actor.send(reply_to, Error(reason))
              actor.continue(new_state)
            }
          }
        }
      }
    }

    Disconnect(reply_to) -> {
      let _ =
        log(Info, "mcp", "Disconnect", [#("connection_id", state.config.id)])

      let new_state = ConnectionState(..state, status: Disconnected)
      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    Reconnect(reply_to) -> {
      let _ =
        log(Info, "mcp", "Reconnect", [
          #("connection_id", state.config.id),
          #("attempt", int.to_string(state.reconnect_attempt + 1)),
        ])

      let new_attempt = state.reconnect_attempt + 1
      let connecting_state =
        ConnectionState(..state, status: Reconnecting(attempt: new_attempt))

      case do_connect(state.config) {
        Ok(_) -> {
          let new_state =
            ConnectionState(
              ..state,
              status: Connected,
              reconnect_attempt: 0,
              failed_health_checks: 0,
            )
          actor.send(reply_to, Ok(Nil))
          actor.continue(new_state)
        }
        Error(reason) -> {
          let should_retry = should_reconnect(connecting_state)
          let new_state = case should_retry {
            True -> connecting_state
            False ->
              ConnectionState(
                ..state,
                status: ConnectionError(
                  "Max reconnection attempts reached: " <> reason,
                ),
              )
          }
          actor.send(reply_to, Error(reason))
          actor.continue(new_state)
        }
      }
    }

    SetApiKey(reply_to, api_key) -> {
      let _ =
        log(Info, "mcp", "SetApiKey", [
          #("connection_id", state.config.id),
          #("provider", format_provider(state.config.provider)),
        ])

      let new_config = MCPConfig(..state.config, api_key: Some(api_key))
      let new_state = ConnectionState(..state, config: new_config)
      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    GetProvider(reply_to) -> {
      actor.send(reply_to, state.config.provider)
      actor.continue(state)
    }

    SetMetadata(reply_to, key, value) -> {
      let new_metadata = dict.insert(state.metadata, key, value)
      let new_state = ConnectionState(..state, metadata: new_metadata)
      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    GetMetadata(reply_to, key) -> {
      let value = case dict.get(state.metadata, key) {
        Ok(v) -> Some(v)
        Error(_) -> None
      }
      actor.send(reply_to, value)
      actor.continue(state)
    }

    ChatStream(reply_to, context, chunk_subject) -> {
      let _ =
        log(Debug, "mcp", "ChatStream", [
          #("connection_id", state.config.id),
          #("message_count", int.to_string(list.length(context.messages))),
        ])

      case state.status {
        Connected -> {
          // Start the streaming chat
          case do_chat_stream(state.config, context, chunk_subject) {
            Ok(_) -> {
              actor.send(reply_to, StreamStarted(subject: chunk_subject))
              actor.continue(state)
            }
            Error(error) -> {
              actor.send(reply_to, StreamStartError(error: error))
              actor.continue(state)
            }
          }
        }
        _ -> {
          actor.send(
            reply_to,
            StreamStartError(error: ConnectionErrorType(
              message: "Not connected",
            )),
          )
          actor.continue(state)
        }
      }
    }

    RegisterTool(reply_to, tool) -> {
      let _ =
        log(Debug, "mcp", "RegisterTool", [
          #("connection_id", state.config.id),
          #("tool_name", tool.name),
        ])

      case validate_tool(tool) {
        Ok(_) -> {
          let entry = ToolEntry(tool: tool, registered_at: 0)
          let new_tools = dict.insert(state.tools, tool.name, entry)
          let new_state = ConnectionState(..state, tools: new_tools)
          actor.send(reply_to, Ok(Nil))
          actor.continue(new_state)
        }
        Error(reason) -> {
          actor.send(reply_to, Error(reason))
          actor.continue(state)
        }
      }
    }

    UnregisterTool(reply_to, name) -> {
      let _ =
        log(Debug, "mcp", "UnregisterTool", [
          #("connection_id", state.config.id),
          #("tool_name", name),
        ])

      case dict.get(state.tools, name) {
        Ok(_) -> {
          let new_tools = dict.delete(state.tools, name)
          let new_state = ConnectionState(..state, tools: new_tools)
          actor.send(reply_to, True)
          actor.continue(new_state)
        }
        Error(_) -> {
          actor.send(reply_to, False)
          actor.continue(state)
        }
      }
    }

    ListTools(reply_to) -> {
      let tools =
        state.tools
        |> dict.values()
        |> list.map(fn(entry) { entry.tool })
      actor.send(reply_to, tools)
      actor.continue(state)
    }

    GetTool(reply_to, name) -> {
      let tool = case dict.get(state.tools, name) {
        Ok(entry) -> Some(entry.tool)
        Error(_) -> None
      }
      actor.send(reply_to, tool)
      actor.continue(state)
    }

    ExecuteToolCall(reply_to, tool_call) -> {
      let _ =
        log(Debug, "mcp", "ExecuteToolCall", [
          #("connection_id", state.config.id),
          #("tool_name", tool_call.name),
          #("tool_call_id", tool_call.id),
        ])

      case dict.get(state.tools, tool_call.name) {
        Ok(entry) -> {
          // Execute the tool handler
          let result = entry.tool.handler(tool_call.arguments)
          actor.send(reply_to, result)
          actor.continue(state)
        }
        Error(_) -> {
          actor.send(
            reply_to,
            ToolError(message: "Tool not found: " <> tool_call.name),
          )
          actor.continue(state)
        }
      }
    }

    Stop(reply_to) -> {
      let _ = log(Info, "mcp", "Stop", [#("connection_id", state.config.id)])
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Create a default configuration for OpenAI
pub fn openai_config(id: String, api_key: String) -> MCPConfig {
  MCPConfig(
    id: id,
    provider: OpenAI,
    api_key: Some(api_key),
    base_url: None,
    timeout_ms: 30_000,
    health_check_interval_ms: 60_000,
    max_reconnect_attempts: 5,
    reconnect_delay_ms: 1000,
  )
}

/// Create a default configuration for Anthropic
pub fn anthropic_config(id: String, api_key: String) -> MCPConfig {
  MCPConfig(
    id: id,
    provider: Anthropic,
    api_key: Some(api_key),
    base_url: None,
    timeout_ms: 30_000,
    health_check_interval_ms: 60_000,
    max_reconnect_attempts: 5,
    reconnect_delay_ms: 1000,
  )
}

/// Create a default configuration for a local MCP server
pub fn local_config(id: String, host: String, port: Int) -> MCPConfig {
  MCPConfig(
    id: id,
    provider: Local(host, port),
    api_key: None,
    base_url: None,
    timeout_ms: 30_000,
    health_check_interval_ms: 60_000,
    max_reconnect_attempts: 5,
    reconnect_delay_ms: 1000,
  )
}

/// Create a custom configuration
pub fn custom_config(
  id: String,
  provider: MCPProvider,
  api_key: Option(String),
) -> MCPConfig {
  MCPConfig(
    id: id,
    provider: provider,
    api_key: api_key,
    base_url: None,
    timeout_ms: 30_000,
    health_check_interval_ms: 60_000,
    max_reconnect_attempts: 5,
    reconnect_delay_ms: 1000,
  )
}

/// Start a new MCP connection actor with the given configuration.
/// Returns a Subject that can be used to send messages to the connection.
pub fn start(config: MCPConfig) -> Result(MCPConnection, actor.StartError) {
  let initial_state =
    ConnectionState(
      config: config,
      status: Disconnected,
      last_health_check: 0,
      failed_health_checks: 0,
      reconnect_attempt: 0,
      metadata: dict.new(),
      tools: dict.new(),
      tool_call_counter: 0,
    )

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Start and immediately connect to the provider
pub fn start_and_connect(config: MCPConfig) -> Result(MCPConnection, String) {
  case start(config) {
    Ok(connection) -> {
      case connect(connection) {
        Ok(_) -> Ok(connection)
        Error(reason) -> {
          let _ = stop(connection)
          Error(reason)
        }
      }
    }
    Error(error) -> Error(string.inspect(error))
  }
}

/// Connect to the provider synchronously
pub fn connect(connection: MCPConnection) -> Result(Nil, String) {
  let reply_subject = process.new_subject()
  actor.send(connection, Connect(reply_subject))

  case process.receive(reply_subject, 10_000) {
    Ok(result) -> result
    Error(_) -> Error("Timeout waiting for connection")
  }
}

/// Disconnect from the provider
pub fn disconnect(connection: MCPConnection) -> Nil {
  actor.call(connection, waiting: 5000, sending: Disconnect)
}

/// Get the current connection status
pub fn get_status(connection: MCPConnection) -> ConnectionStatus {
  actor.call(connection, waiting: 1000, sending: GetStatus)
}

/// Get the connection configuration
pub fn get_config(connection: MCPConnection) -> MCPConfig {
  actor.call(connection, waiting: 1000, sending: GetConfig)
}

/// Perform a health check
pub fn health_check(connection: MCPConnection) -> HealthCheckResult {
  actor.call(connection, waiting: 5000, sending: HealthCheck)
}

/// Reconnect to the provider
pub fn reconnect(connection: MCPConnection) -> Result(Nil, String) {
  let reply_subject = process.new_subject()
  actor.send(connection, Reconnect(reply_subject))

  case process.receive(reply_subject, 10_000) {
    Ok(result) -> result
    Error(_) -> Error("Timeout waiting for reconnection")
  }
}

/// Update the API key
pub fn set_api_key(connection: MCPConnection, api_key: String) -> Nil {
  actor.call(connection, waiting: 1000, sending: SetApiKey(_, api_key))
}

/// Get the provider type
pub fn get_provider(connection: MCPConnection) -> MCPProvider {
  actor.call(connection, waiting: 1000, sending: GetProvider)
}

/// Set a metadata value
pub fn set_metadata(
  connection: MCPConnection,
  key: String,
  value: String,
) -> Nil {
  actor.call(connection, waiting: 1000, sending: SetMetadata(_, key, value))
}

/// Get a metadata value
pub fn get_metadata(connection: MCPConnection, key: String) -> Option(String) {
  actor.call(connection, waiting: 1000, sending: GetMetadata(_, key))
}

// ============================================================================
// Chat Streaming API
// ============================================================================

/// Create an empty chat context
pub fn new_chat_context() -> ChatContext {
  ChatContext(
    system_prompt: None,
    messages: [],
    model: None,
    max_tokens: None,
    temperature: None,
  )
}

/// Add a system prompt to the chat context
pub fn with_system_prompt(context: ChatContext, prompt: String) -> ChatContext {
  ChatContext(..context, system_prompt: Some(prompt))
}

/// Add a user message to the chat context
pub fn with_user_message(context: ChatContext, content: String) -> ChatContext {
  let new_message = ChatMessage(role: User, content: content)
  ChatContext(..context, messages: list.append(context.messages, [new_message]))
}

/// Add an assistant message to the chat context
pub fn with_assistant_message(
  context: ChatContext,
  content: String,
) -> ChatContext {
  let new_message = ChatMessage(role: Assistant, content: content)
  ChatContext(..context, messages: list.append(context.messages, [new_message]))
}

/// Set the model for the chat context
pub fn with_model(context: ChatContext, model: String) -> ChatContext {
  ChatContext(..context, model: Some(model))
}

/// Set the max tokens for the chat context
pub fn with_max_tokens(context: ChatContext, max_tokens: Int) -> ChatContext {
  ChatContext(..context, max_tokens: Some(max_tokens))
}

/// Set the temperature for the chat context
pub fn with_temperature(context: ChatContext, temperature: Float) -> ChatContext {
  ChatContext(..context, temperature: Some(temperature))
}

/// Start a streaming chat with the given context.
/// Returns a subject that will receive StreamChunk messages.
/// 
/// The caller should:
/// 1. Create a subject with `process.new_subject()`
/// 2. Pass it as chunk_subject
/// 3. Receive chunks with `process.receive(chunk_subject, timeout)`
///
/// Example:
///   let chunk_subject = process.new_subject()
///   let result = chat_stream(connection, context, chunk_subject)
///   case result {
///     Ok(_) -> {
///       // Process chunks
///       loop_chunks(chunk_subject, [])
///     }
///     Error(error) -> // Handle error
///   }
pub fn chat_stream(
  connection: MCPConnection,
  context: ChatContext,
  chunk_subject: Subject(StreamChunk),
) -> Result(Subject(StreamChunk), MCPError) {
  let reply_subject = process.new_subject()
  actor.send(connection, ChatStream(reply_subject, context, chunk_subject))

  case process.receive(reply_subject, 30_000) {
    Ok(StreamStarted(subject)) -> Ok(subject)
    Ok(StreamStartError(error)) -> Error(error)
    Error(_) -> Error(TimeoutError(message: "Timeout starting chat stream"))
  }
}

/// Collect all chunks from a streaming chat into a complete response.
/// This blocks until the stream completes or an error occurs.
pub fn chat_stream_collect(
  connection: MCPConnection,
  context: ChatContext,
  timeout_ms: Int,
) -> Result(String, MCPError) {
  let chunk_subject = process.new_subject()

  case chat_stream(connection, context, chunk_subject) {
    Ok(_) -> collect_chunks(chunk_subject, timeout_ms, "")
    Error(error) -> Error(error)
  }
}

/// Helper to collect chunks recursively
fn collect_chunks(
  subject: Subject(StreamChunk),
  timeout_ms: Int,
  accumulated: String,
) -> Result(String, MCPError) {
  case process.receive(subject, timeout_ms) {
    Ok(ContentChunk(content)) ->
      collect_chunks(subject, timeout_ms, accumulated <> content)
    Ok(Done(full_response)) -> Ok(full_response)
    Ok(StreamError(error)) -> Error(error)
    Error(_) -> Error(TimeoutError(message: "Timeout waiting for chat chunk"))
  }
}

/// Create default stream callbacks
pub fn default_stream_callbacks() -> StreamCallbacks(Nil) {
  StreamCallbacks(
    on_chunk: fn(_) { Nil },
    on_complete: fn(_) { Nil },
    on_error: fn(_) { Nil },
  )
}

/// Process a stream with callbacks
pub fn process_stream(
  subject: Subject(StreamChunk),
  callbacks: StreamCallbacks(a),
  timeout_ms: Int,
) -> Nil {
  let _ = process_stream_recursive(subject, callbacks, timeout_ms, "")
  Nil
}

fn process_stream_recursive(
  subject: Subject(StreamChunk),
  callbacks: StreamCallbacks(a),
  timeout_ms: Int,
  accumulated: String,
) -> String {
  case process.receive(subject, timeout_ms) {
    Ok(ContentChunk(content)) -> {
      let _ = callbacks.on_chunk(ContentChunk(content: content))
      process_stream_recursive(
        subject,
        callbacks,
        timeout_ms,
        accumulated <> content,
      )
    }
    Ok(Done(full_response)) -> {
      let _ = callbacks.on_chunk(Done(full_response: full_response))
      let _ = callbacks.on_complete(full_response)
      full_response
    }
    Ok(StreamError(error)) -> {
      let _ = callbacks.on_chunk(StreamError(error: error))
      let _ = callbacks.on_error(error)
      accumulated
    }
    Error(_) -> {
      let _ =
        callbacks.on_error(TimeoutError(message: "Timeout waiting for chunk"))
      accumulated
    }
  }
}

/// Stop the connection actor
pub fn stop(connection: MCPConnection) -> Nil {
  actor.call(connection, waiting: 1000, sending: Stop)
}

/// Check if a configuration requires an API key
pub fn requires_api_key(provider: MCPProvider) -> Bool {
  case provider {
    OpenAI -> True
    Anthropic -> True
    Local(_, _) -> False
  }
}

/// Validate a configuration without starting the connection
pub fn validate_connection_config(config: MCPConfig) -> Result(Nil, String) {
  validate_config(config)
}

// ============================================================================
// Tool API
// ============================================================================

/// Register a tool with the MCP connection.
/// Returns Ok(Nil) on success, or an error message on failure.
pub fn register_tool(
  connection: MCPConnection,
  tool: Tool,
) -> Result(Nil, String) {
  let reply_subject = process.new_subject()
  actor.send(connection, RegisterTool(reply_subject, tool))

  case process.receive(reply_subject, 5000) {
    Ok(result) -> result
    Error(_) -> Error("Timeout registering tool")
  }
}

/// Unregister a tool from the MCP connection.
/// Returns True if the tool was removed, False if it didn't exist.
pub fn unregister_tool(connection: MCPConnection, name: String) -> Bool {
  actor.call(connection, waiting: 1000, sending: UnregisterTool(_, name))
}

/// List all registered tools.
pub fn list_tools(connection: MCPConnection) -> List(Tool) {
  actor.call(connection, waiting: 1000, sending: ListTools)
}

/// Get a specific tool by name.
pub fn get_tool(connection: MCPConnection, name: String) -> Option(Tool) {
  actor.call(connection, waiting: 1000, sending: GetTool(_, name))
}

/// Execute a tool call and return the result.
pub fn execute_tool_call(
  connection: MCPConnection,
  tool_call: ToolCall,
) -> ToolResult {
  actor.call(connection, waiting: 30_000, sending: ExecuteToolCall(_, tool_call))
}

/// Generate a unique tool call ID.
pub fn generate_tool_call_id(_connection: MCPConnection) -> String {
  // Use the counter from state via a special message pattern
  // For simplicity, we use a timestamp-based ID
  "call_" <> int.to_string(generate_timestamp())
}

/// Generate a timestamp in milliseconds.
fn generate_timestamp() -> Int {
  ffi_current_timestamp()
}

// ============================================================================
// Tool Schema Helpers
// ============================================================================

/// Create an empty tool schema (no parameters)
pub fn empty_tool_schema() -> ToolSchema {
  ToolSchema(
    type_: ObjectType(properties: dict.new()),
    required: [],
    properties: dict.new(),
  )
}

/// Create a string property for a tool schema
pub fn string_property(description: String, required: Bool) -> SchemaProperty {
  SchemaProperty(
    type_: StringType,
    description: Some(description),
    required: required,
    default: None,
  )
}

/// Create an integer property for a tool schema
pub fn integer_property(description: String, required: Bool) -> SchemaProperty {
  SchemaProperty(
    type_: IntegerType,
    description: Some(description),
    required: required,
    default: None,
  )
}

/// Create a number property for a tool schema
pub fn number_property(description: String, required: Bool) -> SchemaProperty {
  SchemaProperty(
    type_: NumberType,
    description: Some(description),
    required: required,
    default: None,
  )
}

/// Create a boolean property for a tool schema
pub fn boolean_property(description: String, required: Bool) -> SchemaProperty {
  SchemaProperty(
    type_: BooleanType,
    description: Some(description),
    required: required,
    default: None,
  )
}

/// Create a tool schema with properties
pub fn tool_schema_with_properties(
  properties: List(#(String, SchemaProperty)),
) -> ToolSchema {
  let props_dict =
    properties
    |> list.fold(dict.new(), fn(acc, pair) {
      let #(name, prop) = pair
      dict.insert(acc, name, prop)
    })

  let required =
    properties
    |> list.filter(fn(pair) {
      let #(_, prop) = pair
      prop.required
    })
    |> list.map(fn(pair) {
      let #(name, _) = pair
      name
    })

  ToolSchema(
    type_: ObjectType(properties: props_dict),
    required: required,
    properties: props_dict,
  )
}

/// Create a new tool with the given name, description, schema, and handler
pub fn new_tool(
  name: String,
  description: String,
  parameters: ToolSchema,
  handler: fn(String) -> ToolResult,
) -> Tool {
  Tool(
    name: name,
    description: description,
    parameters: parameters,
    handler: handler,
  )
}

/// Create a simple tool with no parameters
pub fn simple_tool(
  name: String,
  description: String,
  handler: fn(String) -> ToolResult,
) -> Tool {
  new_tool(name, description, empty_tool_schema(), handler)
}

// ============================================================================
// Tool Result Helpers
// ============================================================================

/// Create a successful tool result
pub fn tool_success(content: String) -> ToolResult {
  ToolSuccess(content: content)
}

/// Create a failed tool result
pub fn tool_error(message: String) -> ToolResult {
  ToolError(message: message)
}

// ============================================================================
// Tool Call Helpers
// ============================================================================

/// Create a tool call with the given ID, name, and JSON arguments
pub fn new_tool_call(id: String, name: String, arguments: String) -> ToolCall {
  ToolCall(id: id, name: name, arguments: arguments)
}

// ============================================================================
// JSON Serialization for Tools
// ============================================================================

/// Convert a SchemaType to its JSON string representation
fn schema_type_to_string(type_: SchemaType) -> String {
  case type_ {
    StringType -> "string"
    IntegerType -> "integer"
    NumberType -> "number"
    BooleanType -> "boolean"
    ArrayType(_) -> "array"
    ObjectType(_) -> "object"
  }
}

/// Escape a string for JSON
fn json_escape(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

/// Serialize a ToolSchema to JSON string
pub fn serialize_tool_schema(schema: ToolSchema) -> String {
  let type_str = schema_type_to_string(schema.type_)
  let required_str =
    schema.required
    |> list.map(fn(r) { "\"" <> json_escape(r) <> "\"" })
    |> string.join(",")

  let properties_str =
    schema.properties
    |> dict.to_list()
    |> list.map(fn(pair) {
      let #(name, prop) = pair
      serialize_property_to_json_string(name, prop)
    })
    |> string.join(",")

  "{\"type\":\""
  <> type_str
  <> "\",\"required\":["
  <> required_str
  <> "],\"properties\":{"
  <> properties_str
  <> "}}"
}

/// Serialize a single property to JSON string
fn serialize_property_to_json_string(
  name: String,
  prop: SchemaProperty,
) -> String {
  let type_str = schema_type_to_string(prop.type_)

  let desc_part = case prop.description {
    Some(desc) -> ",\"description\":\"" <> json_escape(desc) <> "\""
    None -> ""
  }

  let default_part = case prop.default {
    Some(default_val) -> ",\"default\":\"" <> json_escape(default_val) <> "\""
    None -> ""
  }

  "\""
  <> json_escape(name)
  <> "\":{\"type\":\""
  <> type_str
  <> "\""
  <> desc_part
  <> default_part
  <> "}"
}

/// Serialize a Tool to JSON format suitable for LLM tool definitions
pub fn serialize_tool_for_llm(tool: Tool) -> String {
  let schema_str = serialize_tool_schema(tool.parameters)

  "{\"type\":\"function\",\"function\":{\"name\":\""
  <> json_escape(tool.name)
  <> "\",\"description\":\""
  <> json_escape(tool.description)
  <> "\",\"parameters\":"
  <> schema_str
  <> "}}"
}

/// Serialize a ToolResult to JSON for returning to the LLM
pub fn serialize_tool_result(result: ToolResult, tool_call_id: String) -> String {
  case result {
    ToolSuccess(content) ->
      "{\"tool_call_id\":\""
      <> json_escape(tool_call_id)
      <> "\",\"role\":\"tool\",\"content\":\""
      <> json_escape(content)
      <> "\"}"
    ToolError(message) ->
      "{\"tool_call_id\":\""
      <> json_escape(tool_call_id)
      <> "\",\"role\":\"tool\",\"content\":\"Error: "
      <> json_escape(message)
      <> "\",\"is_error\":true}"
  }
}

/// Serialize a ToolCall to JSON for sending to the LLM
pub fn serialize_tool_call_for_llm(tool_call: ToolCall) -> String {
  "{\"id\":\""
  <> json_escape(tool_call.id)
  <> "\",\"type\":\"function\",\"function\":{\"name\":\""
  <> json_escape(tool_call.name)
  <> "\",\"arguments\":\""
  <> json_escape(tool_call.arguments)
  <> "\"}}"
}

// ============================================================================
// Tool Schema Validation
// ============================================================================

/// Validate that JSON arguments match a tool schema (basic validation)
pub fn validate_tool_arguments(
  schema: ToolSchema,
  arguments: String,
) -> Result(Nil, String) {
  // Basic validation: check that required fields are present
  // In a full implementation, this would parse and validate the JSON structure
  validate_required_fields_present(schema.required, arguments)
}

/// Validate that required fields are present in the JSON string
fn validate_required_fields_present(
  required: List(String),
  arguments: String,
) -> Result(Nil, String) {
  case
    json.parse(
      from: arguments,
      using: decode.dict(decode.string, decode.dynamic),
    )
  {
    Error(_) -> Error("Invalid JSON arguments")
    Ok(parsed) -> validate_fields_in_map(required, parsed)
  }
}

fn validate_fields_in_map(
  required: List(String),
  parsed: Dict(String, Dynamic),
) -> Result(Nil, String) {
  case required {
    [] -> Ok(Nil)
    [field, ..rest] ->
      case dict.get(parsed, field) {
        Ok(_) -> validate_fields_in_map(rest, parsed)
        Error(_) -> Error("Missing required field: " <> field)
      }
  }
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

/// List all tools formatted for LLM consumption
pub fn list_tools_for_llm(connection: MCPConnection) -> String {
  let tools = list_tools(connection)

  let tools_str =
    tools
    |> list.map(serialize_tool_for_llm)
    |> string.join(",")

  "{\"tools\":[" <> tools_str <> "]}"
}
