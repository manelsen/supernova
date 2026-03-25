//// Test suite for the Plugin system
//// Tests lifecycle hooks, error isolation, and configuration parsing

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/plugins

pub fn main() -> Nil {
  Nil
}

// ============================================================================
// Plugin Builder Tests
// ============================================================================

pub fn new_plugin_creates_plugin_with_name_test() -> Nil {
  let plugin = plugins.new_plugin("test-plugin")
  plugin.name |> should.equal("test-plugin")
}

pub fn with_description_sets_description_test() -> Nil {
  let plugin =
    plugins.new_plugin("test")
    |> plugins.with_description("A test plugin")

  plugin.description |> should.equal("A test plugin")
}

pub fn with_version_sets_version_test() -> Nil {
  let plugin =
    plugins.new_plugin("test")
    |> plugins.with_version("2.0.0")

  plugin.version |> should.equal("2.0.0")
}

pub fn with_priority_sets_priority_test() -> Nil {
  let plugin =
    plugins.new_plugin("test")
    |> plugins.with_priority(100)

  plugin.priority |> should.equal(100)
}

pub fn with_enabled_sets_enabled_test() -> Nil {
  let plugin =
    plugins.new_plugin("test")
    |> plugins.with_enabled(False)

  plugin.enabled |> should.equal(False)
}

pub fn with_config_sets_initial_config_test() -> Nil {
  let config = dict.from_list([#("key1", "value1"), #("key2", "value2")])
  let plugin =
    plugins.new_plugin("test")
    |> plugins.with_config(config)

  plugin.initial_state.config |> should.equal(config)
}

// ============================================================================
// PluginState Tests
// ============================================================================

pub fn new_plugin_state_creates_empty_state_test() -> Nil {
  let state = plugins.new_plugin_state()
  state.config |> should.equal(dict.new())
  state.data |> should.equal(dict.new())
}

pub fn state_set_config_adds_config_value_test() -> Nil {
  let state =
    plugins.new_plugin_state()
    |> plugins.state_set_config("key", "value")

  plugins.state_get_config(state, "key") |> should.equal(Some("value"))
}

pub fn state_set_data_adds_data_value_test() -> Nil {
  let state =
    plugins.new_plugin_state()
    |> plugins.state_set_data("key", "value")

  plugins.state_get_data(state, "key") |> should.equal(Some("value"))
}

pub fn state_get_config_returns_none_for_missing_key_test() -> Nil {
  let state = plugins.new_plugin_state()
  plugins.state_get_config(state, "missing") |> should.equal(None)
}

pub fn state_get_data_returns_none_for_missing_key_test() -> Nil {
  let state = plugins.new_plugin_state()
  plugins.state_get_data(state, "missing") |> should.equal(None)
}

// ============================================================================
// PluginMessage Tests
// ============================================================================

pub fn new_plugin_message_creates_message_with_content_test() -> Nil {
  let msg = plugins.new_plugin_message("Hello world")
  msg.content |> should.equal("Hello world")
  msg.role |> should.equal("user")
}

pub fn message_with_role_sets_role_test() -> Nil {
  let msg =
    plugins.new_plugin_message("Hello")
    |> plugins.message_with_role("assistant")

  msg.role |> should.equal("assistant")
}

pub fn message_with_source_sets_source_test() -> Nil {
  let msg =
    plugins.new_plugin_message("Hello")
    |> plugins.message_with_source("discord")

  msg.source |> should.equal(Some("discord"))
}

pub fn message_with_metadata_adds_metadata_test() -> Nil {
  let msg =
    plugins.new_plugin_message("Hello")
    |> plugins.message_with_metadata("channel", "general")

  dict.get(msg.metadata, "channel") |> should.equal(Ok("general"))
}

// ============================================================================
// PluginResult Tests
// ============================================================================

pub fn plugin_ok_creates_successful_result_test() -> Nil {
  let state = plugins.new_plugin_state()
  let result = plugins.plugin_ok(state)
  plugins.is_ok(result) |> should.equal(True)
  plugins.is_err(result) |> should.equal(False)
}

pub fn plugin_err_creates_error_result_test() -> Nil {
  let error = plugins.load_error("test", "failed")
  let result = plugins.plugin_err(error)
  plugins.is_ok(result) |> should.equal(False)
  plugins.is_err(result) |> should.equal(True)
}

pub fn plugin_unwrap_returns_value_on_ok_test() -> Nil {
  let state = plugins.new_plugin_state()
  let result = plugins.plugin_ok(state)
  let unwrapped = plugins.plugin_unwrap(result)
  unwrapped.config |> should.equal(dict.new())
}

pub fn plugin_unwrap_or_returns_value_on_ok_test() -> Nil {
  let state = plugins.new_plugin_state()
  let default = plugins.new_plugin_state() |> plugins.state_set_data("x", "y")
  let result = plugins.plugin_ok(state)
  let unwrapped = plugins.plugin_unwrap_or(result, default)
  plugins.state_get_data(unwrapped, "x") |> should.equal(None)
}

pub fn plugin_unwrap_or_returns_default_on_err_test() -> Nil {
  let error = plugins.load_error("test", "failed")
  let result = plugins.plugin_err(error)
  let default = plugins.new_plugin_state() |> plugins.state_set_data("x", "y")
  let unwrapped = plugins.plugin_unwrap_or(result, default)
  plugins.state_get_data(unwrapped, "x") |> should.equal(Some("y"))
}

// ============================================================================
// Error Formatting Tests
// ============================================================================

pub fn format_error_load_error_test() -> Nil {
  let error = plugins.load_error("my-plugin", "Something went wrong")
  let formatted = plugins.format_error(error)
  formatted |> should.equal("LoadError[my-plugin]: Something went wrong")
}

pub fn format_error_message_error_test() -> Nil {
  let error = plugins.message_error("my-plugin", "Message processing failed")
  let formatted = plugins.format_error(error)
  formatted
  |> should.equal("MessageError[my-plugin]: Message processing failed")
}

pub fn format_error_shutdown_error_test() -> Nil {
  let error = plugins.shutdown_error("my-plugin", "Cleanup failed")
  let formatted = plugins.format_error(error)
  formatted |> should.equal("ShutdownError[my-plugin]: Cleanup failed")
}

pub fn format_status_test() -> Nil {
  plugins.format_status(plugins.Loaded) |> should.equal("loaded")
  plugins.format_status(plugins.Active) |> should.equal("active")
  plugins.format_status(plugins.PluginError(reason: "failed"))
  |> should.equal("error: failed")
  plugins.format_status(plugins.Stopped) |> should.equal("stopped")
}

// ============================================================================
// Plugin Registry Tests
// ============================================================================

pub fn start_registry_creates_registry_test() -> Nil {
  let result = plugins.start_registry()
  result |> should.be_ok()

  let assert Ok(registry) = result
  plugins.stop_registry(registry)
}

pub fn register_adds_plugin_to_registry_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()
  let plugin = plugins.new_plugin("test-plugin")

  let result = plugins.register(registry, plugin)
  result |> should.be_ok()

  plugins.stop_registry(registry)
}

pub fn register_rejects_duplicate_plugins_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()
  let plugin = plugins.new_plugin("test-plugin")

  let assert Ok(Nil) = plugins.register(registry, plugin)
  let result = plugins.register(registry, plugin)

  result |> should.be_error()

  plugins.stop_registry(registry)
}

pub fn unregister_removes_plugin_from_registry_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()
  let plugin = plugins.new_plugin("test-plugin")

  let assert Ok(Nil) = plugins.register(registry, plugin)
  let result = plugins.unregister(registry, "test-plugin")
  result |> should.be_ok()

  // Verify plugin is gone
  plugins.get_plugin(registry, "test-plugin") |> should.equal(None)

  plugins.stop_registry(registry)
}

pub fn unregister_returns_error_for_missing_plugin_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()

  let result = plugins.unregister(registry, "non-existent")
  result |> should.be_error()

  plugins.stop_registry(registry)
}

pub fn get_plugin_returns_registered_plugin_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()
  let plugin =
    plugins.new_plugin("test-plugin") |> plugins.with_description("Test")

  let assert Ok(Nil) = plugins.register(registry, plugin)

  let result = plugins.get_plugin(registry, "test-plugin")
  result |> should.be_some()

  let assert Some(p) = result
  p.description |> should.equal("Test")

  plugins.stop_registry(registry)
}

pub fn get_plugin_returns_none_for_missing_plugin_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()

  plugins.get_plugin(registry, "non-existent") |> should.equal(None)

  plugins.stop_registry(registry)
}

pub fn list_plugins_returns_all_plugins_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()
  let plugin1 = plugins.new_plugin("plugin-1")
  let plugin2 = plugins.new_plugin("plugin-2")

  let assert Ok(Nil) = plugins.register(registry, plugin1)
  let assert Ok(Nil) = plugins.register(registry, plugin2)

  let result = plugins.list_plugins(registry)
  list.length(result) |> should.equal(2)

  plugins.stop_registry(registry)
}

pub fn get_plugin_status_returns_status_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()
  let plugin = plugins.new_plugin("test-plugin")

  let assert Ok(Nil) = plugins.register(registry, plugin)

  let status = plugins.get_plugin_status(registry, "test-plugin")
  status |> should.equal(Some(plugins.Loaded))

  plugins.stop_registry(registry)
}

// ============================================================================
// Plugin Lifecycle Tests
// ============================================================================

pub fn load_plugin_calls_on_load_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()

  // Create plugin that modifies state on load
  let plugin =
    plugins.new_plugin("test-plugin")
    |> plugins.with_on_load(fn(state) {
      plugins.plugin_ok(state |> plugins.state_set_data("loaded", "true"))
    })

  let assert Ok(Nil) = plugins.register(registry, plugin)
  let assert Ok(Nil) = plugins.load_plugin(registry, "test-plugin")

  let status = plugins.get_plugin_status(registry, "test-plugin")
  status |> should.equal(Some(plugins.Active))

  plugins.stop_registry(registry)
}

pub fn load_plugin_handles_error_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()

  // Create plugin that fails on load
  let plugin =
    plugins.new_plugin("test-plugin")
    |> plugins.with_on_load(fn(_) {
      plugins.plugin_err(plugins.load_error("test-plugin", "Load failed"))
    })

  let assert Ok(Nil) = plugins.register(registry, plugin)
  let result = plugins.load_plugin(registry, "test-plugin")

  result |> should.be_error()

  let status = plugins.get_plugin_status(registry, "test-plugin")
  case status {
    Some(plugins.PluginError(_)) -> Nil
    _ -> panic as "Expected PluginError status"
  }

  plugins.stop_registry(registry)
}

pub fn shutdown_plugin_calls_on_shutdown_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()

  let shutdown_called = process.new_subject()

  let plugin =
    plugins.new_plugin("test-plugin")
    |> plugins.with_on_shutdown(fn(_) {
      process.send(shutdown_called, True)
      Nil
    })

  let assert Ok(Nil) = plugins.register(registry, plugin)
  let assert Ok(Nil) = plugins.shutdown_plugin(registry, "test-plugin")

  // Verify shutdown was called
  let received = process.receive(shutdown_called, 1000)
  received |> should.equal(Ok(True))

  plugins.stop_registry(registry)
}

// ============================================================================
// Message Processing Tests
// ============================================================================

pub fn notify_message_processes_all_plugins_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()

  let plugin =
    plugins.new_plugin("test-plugin")
    |> plugins.with_on_message(fn(state, msg) {
      let new_state =
        state |> plugins.state_set_data("last_message", msg.content)
      plugins.plugin_ok(new_state)
    })

  let assert Ok(Nil) = plugins.register(registry, plugin)

  let msg = plugins.new_plugin_message("Hello world")
  let assert Ok(Nil) = plugins.notify_message(registry, msg)

  plugins.stop_registry(registry)
}

pub fn notify_message_respects_priority_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()

  let subject = process.new_subject()

  // Low priority plugin (runs second)
  let low_plugin =
    plugins.new_plugin("low-priority")
    |> plugins.with_priority(1)
    |> plugins.with_on_message(fn(state, msg) {
      process.send(subject, "low: " <> msg.content)
      plugins.plugin_ok(state)
    })

  // High priority plugin (runs first)
  let high_plugin =
    plugins.new_plugin("high-priority")
    |> plugins.with_priority(10)
    |> plugins.with_on_message(fn(state, msg) {
      process.send(subject, "high: " <> msg.content)
      plugins.plugin_ok(state)
    })

  let assert Ok(Nil) = plugins.register(registry, low_plugin)
  let assert Ok(Nil) = plugins.register(registry, high_plugin)

  let msg = plugins.new_plugin_message("test")
  let assert Ok(Nil) = plugins.notify_message(registry, msg)

  // High priority should be first
  let first = process.receive(subject, 1000)
  first |> should.equal(Ok("high: test"))

  let second = process.receive(subject, 1000)
  second |> should.equal(Ok("low: test"))

  plugins.stop_registry(registry)
}

pub fn notify_message_skips_disabled_plugins_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()

  let subject = process.new_subject()

  let enabled_plugin =
    plugins.new_plugin("enabled")
    |> plugins.with_on_message(fn(state, _) {
      process.send(subject, "enabled")
      plugins.plugin_ok(state)
    })

  let disabled_plugin =
    plugins.new_plugin("disabled")
    |> plugins.with_enabled(False)
    |> plugins.with_on_message(fn(state, _) {
      process.send(subject, "disabled")
      plugins.plugin_ok(state)
    })

  let assert Ok(Nil) = plugins.register(registry, enabled_plugin)
  let assert Ok(Nil) = plugins.register(registry, disabled_plugin)

  let msg = plugins.new_plugin_message("test")
  let assert Ok(Nil) = plugins.notify_message(registry, msg)

  // Only enabled plugin should have processed
  let result = process.receive(subject, 1000)
  result |> should.equal(Ok("enabled"))

  // Disabled plugin should not have sent anything
  let no_result = process.receive(subject, 100)
  no_result |> should.be_error()

  plugins.stop_registry(registry)
}

// ============================================================================
// Error Isolation Tests
// ============================================================================

pub fn error_isolation_continues_after_plugin_error_test() -> Nil {
  let assert Ok(registry) = plugins.start_registry()

  let subject = process.new_subject()

  // Plugin that will error
  let error_plugin =
    plugins.new_plugin("error-plugin")
    |> plugins.with_priority(10)
    |> plugins.with_on_message(fn(_, _) {
      plugins.plugin_err(plugins.message_error("error-plugin", "Failed"))
    })

  // Plugin that should still run
  let ok_plugin =
    plugins.new_plugin("ok-plugin")
    |> plugins.with_priority(1)
    |> plugins.with_on_message(fn(state, _) {
      process.send(subject, "ok-plugin ran")
      plugins.plugin_ok(state)
    })

  let assert Ok(Nil) = plugins.register(registry, error_plugin)
  let assert Ok(Nil) = plugins.register(registry, ok_plugin)

  let msg = plugins.new_plugin_message("test")
  let assert Ok(Nil) = plugins.notify_message(registry, msg)

  // ok-plugin should still have run despite error-plugin failing
  let result = process.receive(subject, 1000)
  result |> should.equal(Ok("ok-plugin ran"))

  // error-plugin should have error status
  let status = plugins.get_plugin_status(registry, "error-plugin")
  case status {
    Some(plugins.PluginError(_)) -> Nil
    _ -> panic as "Expected PluginError status for error-plugin"
  }

  plugins.stop_registry(registry)
}

// ============================================================================
// YAML Configuration Tests
// ============================================================================

pub fn parse_config_yaml_empty_test() -> Nil {
  let yaml = ""
  let result = plugins.parse_config_yaml(yaml)
  result |> should.be_ok()

  let assert Ok(config) = result
  list.length(config.plugins) |> should.equal(0)
}

pub fn parse_config_yaml_single_plugin_test() -> Nil {
  let yaml =
    "
plugins:
  - name: my-plugin
    enabled: true
"

  let result = plugins.parse_config_yaml(yaml)
  result |> should.be_ok()

  let assert Ok(config) = result
  list.length(config.plugins) |> should.equal(1)

  let assert [plugin] = config.plugins
  plugin.name |> should.equal("my-plugin")
  plugin.enabled |> should.equal(True)
}

pub fn parse_config_yaml_multiple_plugins_test() -> Nil {
  let yaml =
    "
plugins:
  - name: plugin-1
    enabled: true
  - name: plugin-2
    enabled: false
"

  let result = plugins.parse_config_yaml(yaml)
  result |> should.be_ok()

  let assert Ok(config) = result
  list.length(config.plugins) |> should.equal(2)
}

pub fn parse_config_yaml_with_config_test() -> Nil {
  let yaml =
    "
plugins:
  - name: my-plugin
    enabled: true
    config:
      api_key: secret123
      timeout: 30
"

  let result = plugins.parse_config_yaml(yaml)
  result |> should.be_ok()

  let assert Ok(config) = result
  let assert [plugin] = config.plugins

  dict.get(plugin.config, "api_key") |> should.equal(Ok("secret123"))
  dict.get(plugin.config, "timeout") |> should.equal(Ok("30"))
}

pub fn parse_config_yaml_invalid_test() -> Nil {
  let yaml = ":: invalid yaml ::"
  let result = plugins.parse_config_yaml(yaml)
  let _ = result |> should.be_error()
  Nil
}

// ============================================================================
// JSON Configuration Tests
// ============================================================================

pub fn parse_config_json_empty_test() -> Nil {
  let json_str = "{}"
  let result = plugins.parse_config_json(json_str)
  result |> should.be_ok()

  let assert Ok(config) = result
  list.length(config.plugins) |> should.equal(0)
}

pub fn parse_config_json_single_plugin_test() -> Nil {
  let json_str = "{\"plugins\": [{\"name\": \"my-plugin\", \"enabled\": true}]}"
  let result = plugins.parse_config_json(json_str)
  result |> should.be_ok()

  let assert Ok(config) = result
  list.length(config.plugins) |> should.equal(1)

  let assert [plugin] = config.plugins
  plugin.name |> should.equal("my-plugin")
  plugin.enabled |> should.equal(True)
}

pub fn parse_config_json_invalid_test() -> Nil {
  let json_str = "not valid json"
  let result = plugins.parse_config_json(json_str)
  let _ = result |> should.be_error()
  Nil
}

// ============================================================================
// Serialization Tests
// ============================================================================

pub fn serialize_config_test() -> Nil {
  let config =
    plugins.PluginConfig(
      name: "test-plugin",
      enabled: True,
      config: dict.from_list([#("key", "value")]),
    )

  let json_str = plugins.serialize_config(config)
  string.contains(json_str, "\"name\":\"test-plugin\"") |> should.equal(True)
  string.contains(json_str, "\"enabled\":true") |> should.equal(True)
}

pub fn serialize_config_file_test() -> Nil {
  let config =
    plugins.PluginsConfigFile(plugins: [
      plugins.PluginConfig(name: "plugin-1", enabled: True, config: dict.new()),
    ])

  let json_str = plugins.serialize_config_file(config)
  string.contains(json_str, "\"plugins\"") |> should.equal(True)
}

// ============================================================================
// Config to State Conversion Test
// ============================================================================

pub fn config_to_state_test() -> Nil {
  let config =
    plugins.PluginConfig(
      name: "test",
      enabled: True,
      config: dict.from_list([#("key", "value")]),
    )

  let state = plugins.config_to_state(config)
  plugins.state_get_config(state, "key") |> should.equal(Some("value"))
}
