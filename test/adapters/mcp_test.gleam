import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/adapters/mcp

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Configuration Tests
// ============================================================================

pub fn openai_config_has_correct_provider_test() {
  let config = mcp.openai_config("test-openai", "sk-test-key")
  config.provider |> should.equal(mcp.OpenAI)
}

pub fn openai_config_has_api_key_test() {
  let config = mcp.openai_config("test-openai", "sk-test-key")
  config.api_key |> should.equal(Some("sk-test-key"))
}

pub fn anthropic_config_has_correct_provider_test() {
  let config = mcp.anthropic_config("test-anthropic", "sk-ant-key")
  config.provider |> should.equal(mcp.Anthropic)
}

pub fn anthropic_config_has_api_key_test() {
  let config = mcp.anthropic_config("test-anthropic", "sk-ant-key")
  config.api_key |> should.equal(Some("sk-ant-key"))
}

pub fn local_config_has_correct_provider_test() {
  let config = mcp.local_config("test-local", "localhost", 8080)
  config.provider |> should.equal(mcp.Local("localhost", 8080))
}

pub fn local_config_has_no_api_key_test() {
  let config = mcp.local_config("test-local", "localhost", 8080)
  config.api_key |> should.equal(None)
}

pub fn custom_config_sets_values_test() {
  let config =
    mcp.custom_config("test-custom", mcp.Anthropic, Some("custom-key"))
  config.id |> should.equal("test-custom")
  config.provider |> should.equal(mcp.Anthropic)
  config.api_key |> should.equal(Some("custom-key"))
}

pub fn requires_api_key_for_openai_test() {
  mcp.requires_api_key(mcp.OpenAI) |> should.equal(True)
}

pub fn requires_api_key_for_anthropic_test() {
  mcp.requires_api_key(mcp.Anthropic) |> should.equal(True)
}

pub fn no_api_key_required_for_local_test() {
  mcp.requires_api_key(mcp.Local("localhost", 8080)) |> should.equal(False)
}

// ============================================================================
// Configuration Validation Tests
// ============================================================================

pub fn validate_openai_config_without_api_key_fails_test() {
  let config =
    mcp.MCPConfig(
      id: "test",
      provider: mcp.OpenAI,
      api_key: None,
      base_url: None,
      timeout_ms: 30_000,
      health_check_interval_ms: 60_000,
      max_reconnect_attempts: 5,
      reconnect_delay_ms: 1000,
    )
  mcp.validate_connection_config(config) |> should.be_error()
}

pub fn validate_anthropic_config_without_api_key_fails_test() {
  let config =
    mcp.MCPConfig(
      id: "test",
      provider: mcp.Anthropic,
      api_key: None,
      base_url: None,
      timeout_ms: 30_000,
      health_check_interval_ms: 60_000,
      max_reconnect_attempts: 5,
      reconnect_delay_ms: 1000,
    )
  mcp.validate_connection_config(config) |> should.be_error()
}

pub fn validate_local_config_without_api_key_succeeds_test() {
  let config = mcp.local_config("test-local", "localhost", 8080)
  mcp.validate_connection_config(config) |> should.equal(Ok(Nil))
}

pub fn validate_openai_config_with_api_key_succeeds_test() {
  let config = mcp.openai_config("test-openai", "sk-test-key")
  mcp.validate_connection_config(config) |> should.equal(Ok(Nil))
}

// ============================================================================
// Actor Lifecycle Tests
// ============================================================================

pub fn start_creates_disconnected_connection_test() {
  let config = mcp.local_config("test-1", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  mcp.get_status(connection) |> should.equal(mcp.Disconnected)

  mcp.stop(connection)
}

pub fn start_and_connect_creates_connected_connection_test() {
  let config = mcp.local_config("test-2", "localhost", 8080)
  let assert Ok(connection) = mcp.start_and_connect(config)

  mcp.get_status(connection) |> should.equal(mcp.Connected)

  mcp.stop(connection)
}

pub fn stop_terminates_connection_test() {
  let config = mcp.local_config("test-3", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  mcp.stop(connection)
  // After stop, the connection is terminated
}

// ============================================================================
// Connection Management Tests
// ============================================================================

pub fn connect_changes_status_to_connected_test() {
  let config = mcp.local_config("test-4", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  mcp.get_status(connection) |> should.equal(mcp.Disconnected)

  let assert Ok(Nil) = mcp.connect(connection)
  mcp.get_status(connection) |> should.equal(mcp.Connected)

  mcp.stop(connection)
}

pub fn connect_when_already_connected_is_idempotent_test() {
  let config = mcp.local_config("test-5", "localhost", 8080)
  let assert Ok(connection) = mcp.start_and_connect(config)

  // Connecting again should succeed
  let assert Ok(Nil) = mcp.connect(connection)
  mcp.get_status(connection) |> should.equal(mcp.Connected)

  mcp.stop(connection)
}

pub fn disconnect_changes_status_to_disconnected_test() {
  let config = mcp.local_config("test-6", "localhost", 8080)
  let assert Ok(connection) = mcp.start_and_connect(config)

  mcp.disconnect(connection)
  mcp.get_status(connection) |> should.equal(mcp.Disconnected)

  mcp.stop(connection)
}

pub fn reconnect_from_disconnected_state_test() {
  let config = mcp.local_config("test-7", "localhost", 8080)
  let assert Ok(connection) = mcp.start_and_connect(config)

  mcp.disconnect(connection)
  mcp.get_status(connection) |> should.equal(mcp.Disconnected)

  let assert Ok(Nil) = mcp.reconnect(connection)
  mcp.get_status(connection) |> should.equal(mcp.Connected)

  mcp.stop(connection)
}

// ============================================================================
// Health Check Tests
// ============================================================================

pub fn health_check_on_connected_returns_healthy_test() {
  let config = mcp.local_config("test-8", "localhost", 8080)
  let assert Ok(connection) = mcp.start_and_connect(config)

  let result = mcp.health_check(connection)

  case result {
    mcp.Healthy(_) -> should.equal(True, True)
    mcp.Unhealthy(_) -> should.equal(True, False)
  }

  mcp.stop(connection)
}

pub fn health_check_on_disconnected_returns_unhealthy_test() {
  let config = mcp.local_config("test-9", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let result = mcp.health_check(connection)

  case result {
    mcp.Healthy(_) -> should.equal(True, False)
    mcp.Unhealthy(_) -> should.equal(True, True)
  }

  mcp.stop(connection)
}

// ============================================================================
// Configuration Retrieval Tests
// ============================================================================

pub fn get_config_returns_original_config_test() {
  let config = mcp.local_config("test-10", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let retrieved = mcp.get_config(connection)
  retrieved.id |> should.equal("test-10")

  mcp.stop(connection)
}

pub fn get_provider_returns_correct_provider_test() {
  let config = mcp.openai_config("test-11", "sk-test-key")
  let assert Ok(connection) = mcp.start(config)

  mcp.get_provider(connection) |> should.equal(mcp.OpenAI)

  mcp.stop(connection)
}

// ============================================================================
// API Key Management Tests
// ============================================================================

pub fn set_api_key_updates_config_test() {
  let config =
    mcp.MCPConfig(
      id: "test-12",
      provider: mcp.OpenAI,
      api_key: None,
      base_url: None,
      timeout_ms: 30_000,
      health_check_interval_ms: 60_000,
      max_reconnect_attempts: 5,
      reconnect_delay_ms: 1000,
    )
  let assert Ok(connection) = mcp.start(config)

  mcp.set_api_key(connection, "new-key")

  let updated_config = mcp.get_config(connection)
  updated_config.api_key |> should.equal(Some("new-key"))

  mcp.stop(connection)
}

// ============================================================================
// Metadata Tests
// ============================================================================

pub fn set_and_get_metadata_test() {
  let config = mcp.local_config("test-13", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  mcp.set_metadata(connection, "environment", "production")

  mcp.get_metadata(connection, "environment")
  |> should.equal(Some("production"))

  mcp.stop(connection)
}

pub fn get_nonexistent_metadata_returns_none_test() {
  let config = mcp.local_config("test-14", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  mcp.get_metadata(connection, "nonexistent") |> should.equal(None)

  mcp.stop(connection)
}

pub fn metadata_can_be_updated_test() {
  let config = mcp.local_config("test-15", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  mcp.set_metadata(connection, "key", "value1")
  mcp.set_metadata(connection, "key", "value2")

  mcp.get_metadata(connection, "key") |> should.equal(Some("value2"))

  mcp.stop(connection)
}

// ============================================================================
// Multiple Provider Tests
// ============================================================================

pub fn multiple_connections_can_coexist_test() {
  let config1 = mcp.local_config("test-16a", "localhost", 8080)
  let config2 = mcp.local_config("test-16b", "localhost", 8081)
  let config3 = mcp.openai_config("test-16c", "sk-test-key")

  let assert Ok(conn1) = mcp.start_and_connect(config1)
  let assert Ok(conn2) = mcp.start_and_connect(config2)
  let assert Ok(conn3) = mcp.start(config3)

  mcp.get_status(conn1) |> should.equal(mcp.Connected)
  mcp.get_status(conn2) |> should.equal(mcp.Connected)
  mcp.get_status(conn3) |> should.equal(mcp.Disconnected)

  mcp.get_provider(conn1) |> should.equal(mcp.Local("localhost", 8080))
  mcp.get_provider(conn2) |> should.equal(mcp.Local("localhost", 8081))
  mcp.get_provider(conn3) |> should.equal(mcp.OpenAI)

  mcp.stop(conn1)
  mcp.stop(conn2)
  mcp.stop(conn3)
}

// ============================================================================
// Reconnection Configuration Tests
// ============================================================================

pub fn config_has_reconnection_settings_test() {
  let config = mcp.local_config("test-17", "localhost", 8080)
  config.max_reconnect_attempts |> should.equal(5)
  config.reconnect_delay_ms |> should.equal(1000)
}

pub fn custom_reconnect_settings_test() {
  let config =
    mcp.MCPConfig(
      id: "test-18",
      provider: mcp.Local("localhost", 8080),
      api_key: None,
      base_url: None,
      timeout_ms: 60_000,
      health_check_interval_ms: 30_000,
      max_reconnect_attempts: 10,
      reconnect_delay_ms: 2000,
    )
  config.max_reconnect_attempts |> should.equal(10)
  config.reconnect_delay_ms |> should.equal(2000)
}

// ============================================================================
// Chat Context Builder Tests
// ============================================================================

pub fn new_chat_context_is_empty_test() {
  let context = mcp.new_chat_context()
  context.system_prompt |> should.equal(None)
  context.messages |> should.equal([])
  context.model |> should.equal(None)
  context.max_tokens |> should.equal(None)
  context.temperature |> should.equal(None)
}

pub fn with_system_prompt_sets_prompt_test() {
  let context =
    mcp.new_chat_context()
    |> mcp.with_system_prompt("You are a helpful assistant.")

  context.system_prompt |> should.equal(Some("You are a helpful assistant."))
}

pub fn with_user_message_adds_message_test() {
  let context =
    mcp.new_chat_context()
    |> mcp.with_user_message("Hello!")

  list.length(context.messages) |> should.equal(1)

  let assert [mcp.ChatMessage(role: mcp.User, content: "Hello!")] =
    context.messages
  Nil
}

pub fn with_assistant_message_adds_message_test() {
  let context =
    mcp.new_chat_context()
    |> mcp.with_assistant_message("Hi there!")

  list.length(context.messages) |> should.equal(1)

  let assert [mcp.ChatMessage(role: mcp.Assistant, content: "Hi there!")] =
    context.messages
  Nil
}

pub fn with_model_sets_model_test() {
  let context =
    mcp.new_chat_context()
    |> mcp.with_model("gpt-4")

  context.model |> should.equal(Some("gpt-4"))
}

pub fn with_max_tokens_sets_tokens_test() {
  let context =
    mcp.new_chat_context()
    |> mcp.with_max_tokens(1000)

  context.max_tokens |> should.equal(Some(1000))
}

pub fn with_temperature_sets_temperature_test() {
  let context =
    mcp.new_chat_context()
    |> mcp.with_temperature(0.7)

  context.temperature |> should.equal(Some(0.7))
}

pub fn chat_context_can_be_chained_test() {
  let context =
    mcp.new_chat_context()
    |> mcp.with_system_prompt("Be helpful.")
    |> mcp.with_user_message("Hello!")
    |> mcp.with_assistant_message("Hi!")
    |> mcp.with_model("gpt-4")
    |> mcp.with_max_tokens(2000)
    |> mcp.with_temperature(0.5)

  context.system_prompt |> should.equal(Some("Be helpful."))
  list.length(context.messages) |> should.equal(2)
  context.model |> should.equal(Some("gpt-4"))
  context.max_tokens |> should.equal(Some(2000))
  context.temperature |> should.equal(Some(0.5))
}

// ============================================================================
// Stream Chunk Type Tests
// ============================================================================

pub fn content_chunk_has_content_test() {
  let chunk = mcp.ContentChunk(content: "Hello")
  chunk.content |> should.equal("Hello")
}

pub fn done_chunk_has_full_response_test() {
  let chunk = mcp.Done(full_response: "Complete response")
  chunk.full_response |> should.equal("Complete response")
}

pub fn stream_error_has_error_test() {
  let chunk = mcp.StreamError(error: mcp.TimeoutError(message: "Timed out"))
  case chunk {
    mcp.StreamError(error: mcp.TimeoutError(message: msg)) ->
      msg |> should.equal("Timed out")
    _ -> should.equal(True, False)
  }
}

// ============================================================================
// MCP Error Type Tests
// ============================================================================

pub fn rate_limit_error_has_retry_after_test() {
  let error =
    mcp.RateLimitError(message: "Too many requests", retry_after_ms: Some(5000))
  error.message |> should.equal("Too many requests")
  error.retry_after_ms |> should.equal(Some(5000))
}

pub fn rate_limit_error_without_retry_after_test() {
  let error = mcp.RateLimitError(message: "Rate limited", retry_after_ms: None)
  error.message |> should.equal("Rate limited")
  error.retry_after_ms |> should.equal(None)
}

pub fn timeout_error_has_message_test() {
  let error = mcp.TimeoutError(message: "Connection timed out")
  error.message |> should.equal("Connection timed out")
}

pub fn provider_error_has_message_test() {
  let error = mcp.ProviderError(message: "Internal server error")
  error.message |> should.equal("Internal server error")
}

pub fn auth_error_has_message_test() {
  let error = mcp.AuthError(message: "Invalid API key")
  error.message |> should.equal("Invalid API key")
}

pub fn config_error_has_message_test() {
  let error = mcp.ConfigError(message: "Missing required field")
  error.message |> should.equal("Missing required field")
}

// ============================================================================
// Stream Callbacks Tests
// ============================================================================

pub fn default_stream_callbacks_exist_test() {
  let callbacks = mcp.default_stream_callbacks()
  // Verify the callbacks can be created
  let _ = callbacks.on_chunk(mcp.ContentChunk(content: "test"))
  let _ = callbacks.on_complete("done")
  let _ = callbacks.on_error(mcp.TimeoutError(message: "test"))
  should.equal(True, True)
}

// ============================================================================
// Chat Stream Tests
// ============================================================================

pub fn chat_stream_on_disconnected_returns_error_test() {
  let config = mcp.local_config("stream-test-1", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let context =
    mcp.new_chat_context()
    |> mcp.with_user_message("Hello!")

  let chunk_subject = process.new_subject()
  let result = mcp.chat_stream(connection, context, chunk_subject)

  case result {
    Error(mcp.ConnectionErrorType(message: _)) -> should.equal(True, True)
    _ -> should.equal(True, False)
  }

  mcp.stop(connection)
}

pub fn chat_stream_on_connected_starts_stream_test() {
  let config = mcp.local_config("stream-test-2", "localhost", 8080)
  let assert Ok(connection) = mcp.start_and_connect(config)

  let context =
    mcp.new_chat_context()
    |> mcp.with_user_message("Hello!")

  let chunk_subject = process.new_subject()
  let result = mcp.chat_stream(connection, context, chunk_subject)

  case result {
    Ok(_) -> should.equal(True, True)
    Error(_) -> should.equal(True, False)
  }

  mcp.stop(connection)
}

pub fn chat_stream_collect_returns_response_test() {
  let config = mcp.local_config("stream-test-3", "localhost", 8080)
  let assert Ok(connection) = mcp.start_and_connect(config)

  let context =
    mcp.new_chat_context()
    |> mcp.with_user_message("Hello!")

  let result = mcp.chat_stream_collect(connection, context, 30_000)

  case result {
    Ok(response) -> should.equal(response |> string.length() > 0, True)
    Error(_) -> should.equal(True, False)
  }

  mcp.stop(connection)
}

pub fn chat_stream_with_system_prompt_test() {
  let config = mcp.local_config("stream-test-4", "localhost", 8080)
  let assert Ok(connection) = mcp.start_and_connect(config)

  let context =
    mcp.new_chat_context()
    |> mcp.with_system_prompt("You are a helpful assistant.")
    |> mcp.with_user_message("Hello!")

  let chunk_subject = process.new_subject()
  let result = mcp.chat_stream(connection, context, chunk_subject)

  case result {
    Ok(_) -> should.equal(True, True)
    Error(_) -> should.equal(True, False)
  }

  mcp.stop(connection)
}

pub fn chat_stream_with_multiple_messages_test() {
  let config = mcp.local_config("stream-test-5", "localhost", 8080)
  let assert Ok(connection) = mcp.start_and_connect(config)

  let context =
    mcp.new_chat_context()
    |> mcp.with_user_message("Hello!")
    |> mcp.with_assistant_message("Hi there!")
    |> mcp.with_user_message("How are you?")

  list.length(context.messages) |> should.equal(3)

  let chunk_subject = process.new_subject()
  let result = mcp.chat_stream(connection, context, chunk_subject)

  case result {
    Ok(_) -> should.equal(True, True)
    Error(_) -> should.equal(True, False)
  }

  mcp.stop(connection)
}

pub fn chat_stream_with_all_options_test() {
  let config = mcp.local_config("stream-test-6", "localhost", 8080)
  let assert Ok(connection) = mcp.start_and_connect(config)

  let context =
    mcp.new_chat_context()
    |> mcp.with_system_prompt("Be concise.")
    |> mcp.with_user_message("What is 2+2?")
    |> mcp.with_model("gpt-4")
    |> mcp.with_max_tokens(100)
    |> mcp.with_temperature(0.3)

  let chunk_subject = process.new_subject()
  let result = mcp.chat_stream(connection, context, chunk_subject)

  case result {
    Ok(_) -> should.equal(True, True)
    Error(_) -> should.equal(True, False)
  }

  mcp.stop(connection)
}

// ============================================================================
// Stream Processing Tests
// ============================================================================

pub fn process_stream_with_callbacks_test() {
  let config = mcp.local_config("stream-process-1", "localhost", 8080)
  let assert Ok(connection) = mcp.start_and_connect(config)

  let context =
    mcp.new_chat_context()
    |> mcp.with_user_message("Hello!")

  let chunk_subject = process.new_subject()
  let _ = mcp.chat_stream(connection, context, chunk_subject)

  // Create callbacks that track what happened
  let callbacks =
    mcp.StreamCallbacks(
      on_chunk: fn(_) { Nil },
      on_complete: fn(_) { Nil },
      on_error: fn(_) { Nil },
    )

  mcp.process_stream(chunk_subject, callbacks, 30_000)

  mcp.stop(connection)
}

// ============================================================================
// Chat Message Type Tests
// ============================================================================

pub fn chat_message_user_role_test() {
  let msg = mcp.ChatMessage(role: mcp.User, content: "Hello")
  msg.role |> should.equal(mcp.User)
  msg.content |> should.equal("Hello")
}

pub fn chat_message_assistant_role_test() {
  let msg = mcp.ChatMessage(role: mcp.Assistant, content: "Hi there!")
  msg.role |> should.equal(mcp.Assistant)
  msg.content |> should.equal("Hi there!")
}

pub fn chat_message_system_role_test() {
  let msg = mcp.ChatMessage(role: mcp.System, content: "You are helpful.")
  msg.role |> should.equal(mcp.System)
  msg.content |> should.equal("You are helpful.")
}

// ============================================================================
// Tool Type Tests
// ============================================================================

pub fn tool_has_name_description_and_handler_test() {
  let tool = create_test_tool("test_tool", "A test tool")
  tool.name |> should.equal("test_tool")
  tool.description |> should.equal("A test tool")
}

pub fn tool_schema_can_be_empty_test() {
  let schema = mcp.empty_tool_schema()
  schema.required |> should.equal([])
}

pub fn string_property_is_created_correctly_test() {
  let prop = mcp.string_property("A string value", True)
  prop.required |> should.equal(True)
  case prop.description {
    Some(desc) -> desc |> should.equal("A string value")
    None -> should.equal(True, False)
  }
}

pub fn integer_property_is_created_correctly_test() {
  let prop = mcp.integer_property("An integer value", True)
  prop.required |> should.equal(True)
}

pub fn boolean_property_is_created_correctly_test() {
  let prop = mcp.boolean_property("A boolean value", False)
  prop.required |> should.equal(False)
}

pub fn number_property_is_created_correctly_test() {
  let prop = mcp.number_property("A number value", True)
  prop.required |> should.equal(True)
}

pub fn tool_schema_with_properties_test() {
  let schema =
    mcp.tool_schema_with_properties([
      #("name", mcp.string_property("The name", True)),
      #("count", mcp.integer_property("The count", False)),
    ])

  schema.required |> should.equal(["name"])
}

pub fn new_tool_creates_tool_with_schema_test() {
  let schema = mcp.empty_tool_schema()
  let tool =
    mcp.new_tool("my_tool", "Does something", schema, fn(_) {
      mcp.tool_success("ok")
    })

  tool.name |> should.equal("my_tool")
  tool.description |> should.equal("Does something")
}

pub fn simple_tool_creates_tool_without_params_test() {
  let tool =
    mcp.simple_tool("simple", "Simple tool", fn(_) { mcp.tool_success("done") })

  tool.name |> should.equal("simple")
  tool.description |> should.equal("Simple tool")
}

// ============================================================================
// Tool Result Tests
// ============================================================================

pub fn tool_success_has_content_test() {
  let result = mcp.tool_success("Operation completed")
  case result {
    mcp.ToolSuccess(content) -> content |> should.equal("Operation completed")
    mcp.ToolError(_) -> should.equal(True, False)
  }
}

pub fn tool_error_has_message_test() {
  let result = mcp.tool_error("Something went wrong")
  case result {
    mcp.ToolSuccess(_) -> should.equal(True, False)
    mcp.ToolError(message) -> message |> should.equal("Something went wrong")
  }
}

// ============================================================================
// Tool Call Tests
// ============================================================================

pub fn tool_call_has_id_name_and_arguments_test() {
  let call = mcp.new_tool_call("call-123", "get_weather", "{\"city\":\"NYC\"}")
  call.id |> should.equal("call-123")
  call.name |> should.equal("get_weather")
  call.arguments |> should.equal("{\"city\":\"NYC\"}")
}

pub fn generate_tool_call_id_returns_string_test() {
  let config = mcp.local_config("test", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let id = mcp.generate_tool_call_id(connection)
  id |> string.starts_with("call_") |> should.equal(True)

  mcp.stop(connection)
}

// ============================================================================
// Tool Registration Tests
// ============================================================================

fn create_test_tool(name: String, description: String) -> mcp.Tool {
  mcp.simple_tool(name, description, fn(_) { mcp.tool_success("ok") })
}

pub fn register_tool_succeeds_test() {
  let config = mcp.local_config("tool-test-1", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let tool = create_test_tool("test_tool", "A test tool")
  let result = mcp.register_tool(connection, tool)

  result |> should.equal(Ok(Nil))

  mcp.stop(connection)
}

pub fn register_tool_with_empty_name_fails_test() {
  let config = mcp.local_config("tool-test-2", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let tool = create_test_tool("", "A test tool")
  let result = mcp.register_tool(connection, tool)

  result |> should.be_error()

  mcp.stop(connection)
}

pub fn register_tool_with_empty_description_fails_test() {
  let config = mcp.local_config("tool-test-3", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let tool = create_test_tool("test_tool", "")
  let result = mcp.register_tool(connection, tool)

  result |> should.be_error()

  mcp.stop(connection)
}

pub fn list_tools_returns_empty_initially_test() {
  let config = mcp.local_config("tool-test-4", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let tools = mcp.list_tools(connection)
  tools |> should.equal([])

  mcp.stop(connection)
}

pub fn list_tools_returns_registered_tools_test() {
  let config = mcp.local_config("tool-test-5", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let tool1 = create_test_tool("tool1", "First tool")
  let tool2 = create_test_tool("tool2", "Second tool")

  let assert Ok(Nil) = mcp.register_tool(connection, tool1)
  let assert Ok(Nil) = mcp.register_tool(connection, tool2)

  let tools = mcp.list_tools(connection)
  list.length(tools) |> should.equal(2)

  mcp.stop(connection)
}

pub fn get_tool_returns_some_for_registered_tool_test() {
  let config = mcp.local_config("tool-test-6", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let tool = create_test_tool("my_tool", "My tool")
  let assert Ok(Nil) = mcp.register_tool(connection, tool)

  let found = mcp.get_tool(connection, "my_tool")
  case found {
    Some(t) -> t.name |> should.equal("my_tool")
    None -> should.equal(True, False)
  }

  mcp.stop(connection)
}

pub fn get_tool_returns_none_for_unregistered_tool_test() {
  let config = mcp.local_config("tool-test-7", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let found = mcp.get_tool(connection, "nonexistent")
  found |> should.equal(None)

  mcp.stop(connection)
}

pub fn unregister_tool_removes_tool_test() {
  let config = mcp.local_config("tool-test-8", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let tool = create_test_tool("to_remove", "Tool to remove")
  let assert Ok(Nil) = mcp.register_tool(connection, tool)

  let removed = mcp.unregister_tool(connection, "to_remove")
  removed |> should.equal(True)

  let found = mcp.get_tool(connection, "to_remove")
  found |> should.equal(None)

  mcp.stop(connection)
}

pub fn unregister_nonexistent_tool_returns_false_test() {
  let config = mcp.local_config("tool-test-9", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let removed = mcp.unregister_tool(connection, "nonexistent")
  removed |> should.equal(False)

  mcp.stop(connection)
}

// ============================================================================
// Tool Execution Tests
// ============================================================================

pub fn execute_tool_call_returns_success_test() {
  let config = mcp.local_config("exec-test-1", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let tool =
    mcp.simple_tool("echo", "Echoes the input", fn(args) {
      mcp.tool_success("Echo: " <> args)
    })

  let assert Ok(Nil) = mcp.register_tool(connection, tool)

  let call = mcp.new_tool_call("call-1", "echo", "hello")
  let result = mcp.execute_tool_call(connection, call)

  case result {
    mcp.ToolSuccess(content) -> content |> should.equal("Echo: hello")
    mcp.ToolError(_) -> should.equal(True, False)
  }

  mcp.stop(connection)
}

pub fn execute_tool_call_returns_error_for_missing_tool_test() {
  let config = mcp.local_config("exec-test-2", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let call = mcp.new_tool_call("call-1", "nonexistent", "{}")
  let result = mcp.execute_tool_call(connection, call)

  case result {
    mcp.ToolSuccess(_) -> should.equal(True, False)
    mcp.ToolError(message) ->
      string.contains(message, "not found") |> should.equal(True)
  }

  mcp.stop(connection)
}

pub fn execute_tool_call_handler_can_return_error_test() {
  let config = mcp.local_config("exec-test-3", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let tool =
    mcp.simple_tool("failing_tool", "Always fails", fn(_) {
      mcp.tool_error("Intentional failure")
    })

  let assert Ok(Nil) = mcp.register_tool(connection, tool)

  let call = mcp.new_tool_call("call-1", "failing_tool", "{}")
  let result = mcp.execute_tool_call(connection, call)

  case result {
    mcp.ToolSuccess(_) -> should.equal(True, False)
    mcp.ToolError(message) -> message |> should.equal("Intentional failure")
  }

  mcp.stop(connection)
}

// ============================================================================
// JSON Serialization Tests
// ============================================================================

pub fn serialize_tool_schema_returns_valid_json_test() {
  let schema =
    mcp.tool_schema_with_properties([
      #("name", mcp.string_property("The name", True)),
    ])

  let json = mcp.serialize_tool_schema(schema)
  json |> string.contains("type") |> should.equal(True)
  json |> string.contains("properties") |> should.equal(True)
}

pub fn serialize_tool_for_llm_includes_name_and_description_test() {
  let tool = create_test_tool("weather", "Get weather info")
  let json = mcp.serialize_tool_for_llm(tool)

  json |> string.contains("weather") |> should.equal(True)
  json |> string.contains("Get weather info") |> should.equal(True)
  json |> string.contains("function") |> should.equal(True)
}

pub fn serialize_tool_result_success_test() {
  let result = mcp.tool_success("The result")
  let json = mcp.serialize_tool_result(result, "call-123")

  json |> string.contains("call-123") |> should.equal(True)
  json |> string.contains("The result") |> should.equal(True)
  json |> string.contains("tool") |> should.equal(True)
}

pub fn serialize_tool_result_error_test() {
  let result = mcp.tool_error("Something failed")
  let json = mcp.serialize_tool_result(result, "call-456")

  json |> string.contains("call-456") |> should.equal(True)
  json |> string.contains("Error:") |> should.equal(True)
  json |> string.contains("is_error") |> should.equal(True)
}

pub fn serialize_tool_call_for_llm_test() {
  let call = mcp.new_tool_call("call-789", "my_tool", "{\"arg\":\"value\"}")
  let json = mcp.serialize_tool_call_for_llm(call)

  json |> string.contains("call-789") |> should.equal(True)
  json |> string.contains("my_tool") |> should.equal(True)
  json |> string.contains("function") |> should.equal(True)
}

pub fn list_tools_for_llm_returns_json_array_test() {
  let config = mcp.local_config("json-test-1", "localhost", 8080)
  let assert Ok(connection) = mcp.start(config)

  let tool1 = create_test_tool("tool1", "First tool")
  let assert Ok(Nil) = mcp.register_tool(connection, tool1)

  let json = mcp.list_tools_for_llm(connection)
  json |> string.contains("tools") |> should.equal(True)
  json |> string.contains("tool1") |> should.equal(True)

  mcp.stop(connection)
}

// ============================================================================
// Tool Argument Validation Tests
// ============================================================================

pub fn validate_tool_arguments_with_empty_required_succeeds_test() {
  let schema = mcp.empty_tool_schema()
  let result = mcp.validate_tool_arguments(schema, "{}")
  result |> should.equal(Ok(Nil))
}

pub fn validate_tool_arguments_with_required_field_present_succeeds_test() {
  let schema =
    mcp.tool_schema_with_properties([
      #("name", mcp.string_property("The name", True)),
    ])

  let result = mcp.validate_tool_arguments(schema, "{\"name\":\"test\"}")
  result |> should.equal(Ok(Nil))
}

pub fn validate_tool_arguments_with_required_field_missing_fails_test() {
  let schema =
    mcp.tool_schema_with_properties([
      #("name", mcp.string_property("The name", True)),
    ])

  let result = mcp.validate_tool_arguments(schema, "{\"other\":\"value\"}")
  result |> should.be_error()
}
