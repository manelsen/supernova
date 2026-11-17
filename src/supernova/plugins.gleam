//// Plugins module for Supernova
//// Implements a plugin system with lifecycle hooks and error isolation.
////
//// This module provides:
//// - Plugin interface with lifecycle hooks (on_load, on_message, on_shutdown)
//// - Plugin registry for managing plugin lifecycle
//// - Plugin configuration via YAML/JSON
//// - Error isolation per plugin (errors don't crash the system)
////
//// ## Usage
////
//// ```gleam
//// // Create a plugin
//// let plugin = new_plugin("my-plugin")
////   |> with_description("Does something cool")
////   |> with_on_load(fn(state) { plugin_ok(state) })
////   |> with_on_message(fn(state, msg) { plugin_ok(state) })
////   |> with_on_shutdown(fn(state) { Nil })
////
//// // Register with registry
//// let assert Ok(registry) = start_registry()
//// let assert Ok(_) = register(registry, plugin)
////
//// // Notify plugins of messages
//// let assert Ok(_) = notify_message(registry, new_plugin_message("Hello world"))
////
//// // Shutdown
//// shutdown_all(registry)
//// ```

import exception
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import yay

// ============================================================================
// Types
// ============================================================================

/// Plugin state passed to lifecycle hooks
pub type PluginState {
  PluginState(
    /// Plugin configuration
    config: Dict(String, String),
    /// Custom data storage
    data: Dict(String, String),
  )
}

/// Message content passed to on_message hook
pub type PluginMessage {
  PluginMessage(
    /// Message content
    content: String,
    /// Message role (user, assistant, system)
    role: String,
    /// Source of the message (discord, telegram, etc.)
    source: Option(String),
    /// Additional metadata
    metadata: Dict(String, String),
  )
}

/// Plugin status
pub type PluginStatus {
  /// Plugin is loaded but not started
  Loaded
  /// Plugin is active and running
  Active
  /// Plugin has encountered an error
  PluginError(reason: String)
  /// Plugin has been stopped
  Stopped
}

/// Result of a plugin hook execution
pub type PluginResult(a) {
  /// Hook executed successfully
  PluginOk(value: a)
  /// Hook encountered an error
  PluginErr(error: PluginError)
}

/// Plugin errors
pub type PluginError {
  /// Error during on_load hook
  LoadError(plugin_name: String, reason: String)
  /// Error during on_message hook
  MessageError(plugin_name: String, reason: String)
  /// Error during on_shutdown hook
  ShutdownError(plugin_name: String, reason: String)
  /// Plugin not found
  PluginNotFound(plugin_name: String, reason: String)
  /// Plugin already registered
  PluginAlreadyRegistered(plugin_name: String, reason: String)
  /// Invalid plugin configuration
  InvalidConfig(plugin_name: String, reason: String)
}

/// A plugin with lifecycle hooks
pub type Plugin {
  Plugin(
    /// Unique plugin identifier
    name: String,
    /// Human-readable description
    description: String,
    /// Plugin version
    version: String,
    /// Plugin priority (higher = executed first)
    priority: Int,
    /// Whether plugin is enabled
    enabled: Bool,
    /// Called when plugin is loaded
    on_load: fn(PluginState) -> PluginResult(PluginState),
    /// Called for each message passing through
    on_message: fn(PluginState, PluginMessage) -> PluginResult(PluginState),
    /// Called when plugin is shut down
    on_shutdown: fn(PluginState) -> Nil,
    /// Initial state
    initial_state: PluginState,
  )
}

/// Internal entry for the plugin registry
type PluginEntry {
  PluginEntry(plugin: Plugin, state: PluginState, status: PluginStatus)
}

/// Plugin registry state
type RegistryState {
  RegistryState(plugins: Dict(String, PluginEntry), message_count: Int)
}

/// Messages for the plugin registry actor
pub type RegistryMessage {
  /// Register a new plugin
  RegisterPlugin(reply_to: Subject(Result(Nil, PluginError)), plugin: Plugin)
  /// Unregister a plugin by name
  UnregisterPlugin(reply_to: Subject(Result(Nil, PluginError)), name: String)
  /// Get a plugin by name
  GetPlugin(reply_to: Subject(Option(Plugin)), name: String)
  /// List all registered plugins
  ListPlugins(reply_to: Subject(List(Plugin)))
  /// Notify all plugins of a message
  NotifyMessage(
    reply_to: Subject(Result(Nil, PluginError)),
    message: PluginMessage,
  )
  /// Load a plugin (call on_load)
  LoadPlugin(reply_to: Subject(Result(Nil, PluginError)), name: String)
  /// Shutdown a plugin
  ShutdownPlugin(reply_to: Subject(Result(Nil, PluginError)), name: String)
  /// Shutdown all plugins
  ShutdownAll(reply_to: Subject(Nil))
  /// Get plugin status
  GetPluginStatus(reply_to: Subject(Option(PluginStatus)), name: String)
  /// Stop the registry
  StopRegistry(reply_to: Subject(Nil))
}

/// Plugin registry handle
pub type PluginRegistry =
  Subject(RegistryMessage)

/// Plugin configuration from YAML/JSON
pub type PluginConfig {
  PluginConfig(
    /// Plugin name
    name: String,
    /// Whether plugin is enabled
    enabled: Bool,
    /// Plugin-specific configuration
    config: Dict(String, String),
  )
}

/// Configuration file for plugins
pub type PluginsConfigFile {
  PluginsConfigFile(
    /// List of plugin configurations
    plugins: List(PluginConfig),
  )
}

/// Configuration parsing error
pub type ConfigParseError {
  /// YAML parsing error
  YamlParseError(message: String)
  /// JSON parsing error
  JsonParseError(message: String)
  /// Missing required field
  MissingField(field: String)
  /// Invalid field type
  InvalidFieldType(field: String, expected: String)
}

// ============================================================================
// Plugin Builders
// ============================================================================

/// Create a new plugin with the given name
pub fn new_plugin(name: String) -> Plugin {
  Plugin(
    name: name,
    description: "",
    version: "1.0.0",
    priority: 0,
    enabled: True,
    on_load: fn(state) { PluginOk(state) },
    on_message: fn(state, _) { PluginOk(state) },
    on_shutdown: fn(_) { Nil },
    initial_state: PluginState(config: dict.new(), data: dict.new()),
  )
}

/// Set plugin description
pub fn with_description(plugin: Plugin, description: String) -> Plugin {
  Plugin(..plugin, description: description)
}

/// Set plugin version
pub fn with_version(plugin: Plugin, version: String) -> Plugin {
  Plugin(..plugin, version: version)
}

/// Set plugin priority
pub fn with_priority(plugin: Plugin, priority: Int) -> Plugin {
  Plugin(..plugin, priority: priority)
}

/// Enable or disable plugin
pub fn with_enabled(plugin: Plugin, enabled: Bool) -> Plugin {
  Plugin(..plugin, enabled: enabled)
}

/// Set on_load hook
pub fn with_on_load(
  plugin: Plugin,
  handler: fn(PluginState) -> PluginResult(PluginState),
) -> Plugin {
  Plugin(..plugin, on_load: handler)
}

/// Set on_message hook
pub fn with_on_message(
  plugin: Plugin,
  handler: fn(PluginState, PluginMessage) -> PluginResult(PluginState),
) -> Plugin {
  Plugin(..plugin, on_message: handler)
}

/// Set on_shutdown hook
pub fn with_on_shutdown(
  plugin: Plugin,
  handler: fn(PluginState) -> Nil,
) -> Plugin {
  Plugin(..plugin, on_shutdown: handler)
}

/// Set initial state
pub fn with_initial_state(plugin: Plugin, state: PluginState) -> Plugin {
  Plugin(..plugin, initial_state: state)
}

/// Set initial config
pub fn with_config(plugin: Plugin, config: Dict(String, String)) -> Plugin {
  let initial_state = PluginState(..plugin.initial_state, config: config)
  Plugin(..plugin, initial_state: initial_state)
}

// ============================================================================
// PluginState Builders
// ============================================================================

/// Create a new plugin state
pub fn new_plugin_state() -> PluginState {
  PluginState(config: dict.new(), data: dict.new())
}

/// Create plugin state with config
pub fn plugin_state_with_config(config: Dict(String, String)) -> PluginState {
  PluginState(config: config, data: dict.new())
}

/// Add config value to state
pub fn state_set_config(
  state: PluginState,
  key: String,
  value: String,
) -> PluginState {
  PluginState(..state, config: dict.insert(state.config, key, value))
}

/// Add data value to state
pub fn state_set_data(
  state: PluginState,
  key: String,
  value: String,
) -> PluginState {
  PluginState(..state, data: dict.insert(state.data, key, value))
}

/// Get config value from state
pub fn state_get_config(state: PluginState, key: String) -> Option(String) {
  case dict.get(state.config, key) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

/// Get data value from state
pub fn state_get_data(state: PluginState, key: String) -> Option(String) {
  case dict.get(state.data, key) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

// ============================================================================
// PluginMessage Builders
// ============================================================================

/// Create a new plugin message
pub fn new_plugin_message(content: String) -> PluginMessage {
  PluginMessage(
    content: content,
    role: "user",
    source: None,
    metadata: dict.new(),
  )
}

/// Set message role
pub fn message_with_role(
  message: PluginMessage,
  role: String,
) -> PluginMessage {
  PluginMessage(..message, role: role)
}

/// Set message source
pub fn message_with_source(
  message: PluginMessage,
  source: String,
) -> PluginMessage {
  PluginMessage(..message, source: Some(source))
}

/// Add metadata to message
pub fn message_with_metadata(
  message: PluginMessage,
  key: String,
  value: String,
) -> PluginMessage {
  PluginMessage(..message, metadata: dict.insert(message.metadata, key, value))
}

// ============================================================================
// Plugin Result Helpers
// ============================================================================

/// Create a successful plugin result
pub fn plugin_ok(state: PluginState) -> PluginResult(PluginState) {
  PluginOk(state)
}

/// Create a plugin error
pub fn plugin_err(error: PluginError) -> PluginResult(PluginState) {
  PluginErr(error)
}

/// Create a load error
pub fn load_error(plugin_name: String, reason: String) -> PluginError {
  LoadError(plugin_name: plugin_name, reason: reason)
}

/// Create a message error
pub fn message_error(plugin_name: String, reason: String) -> PluginError {
  MessageError(plugin_name: plugin_name, reason: reason)
}

/// Create a shutdown error
pub fn shutdown_error(plugin_name: String, reason: String) -> PluginError {
  ShutdownError(plugin_name: plugin_name, reason: reason)
}

// ============================================================================
// Plugin Registry Actor
// ============================================================================

/// Handle registry messages
fn handle_registry_message(
  state: RegistryState,
  message: RegistryMessage,
) -> actor.Next(RegistryState, RegistryMessage) {
  case message {
    RegisterPlugin(reply_to, plugin) -> {
      // Check if plugin already exists
      case dict.get(state.plugins, plugin.name) {
        Ok(_) -> {
          actor.send(
            reply_to,
            Error(PluginAlreadyRegistered(
              plugin_name: plugin.name,
              reason: "Plugin already registered",
            )),
          )
          actor.continue(state)
        }
        Error(_) -> {
          // Create entry
          let entry =
            PluginEntry(
              plugin: plugin,
              state: plugin.initial_state,
              status: Loaded,
            )
          let new_plugins = dict.insert(state.plugins, plugin.name, entry)
          let new_state = RegistryState(..state, plugins: new_plugins)
          actor.send(reply_to, Ok(Nil))
          actor.continue(new_state)
        }
      }
    }

    UnregisterPlugin(reply_to, name) -> {
      case dict.get(state.plugins, name) {
        Ok(entry) -> {
          // Call on_shutdown
          let _ = entry.plugin.on_shutdown(entry.state)
          let new_plugins = dict.delete(state.plugins, name)
          let new_state = RegistryState(..state, plugins: new_plugins)
          actor.send(reply_to, Ok(Nil))
          actor.continue(new_state)
        }
        Error(_) -> {
          actor.send(
            reply_to,
            Error(PluginNotFound(plugin_name: name, reason: "Plugin not found")),
          )
          actor.continue(state)
        }
      }
    }

    GetPlugin(reply_to, name) -> {
      let result = case dict.get(state.plugins, name) {
        Ok(entry) -> Some(entry.plugin)
        Error(_) -> None
      }
      actor.send(reply_to, result)
      actor.continue(state)
    }

    ListPlugins(reply_to) -> {
      let plugins =
        state.plugins
        |> dict.values()
        |> list.map(fn(entry) { entry.plugin })
      actor.send(reply_to, plugins)
      actor.continue(state)
    }

    NotifyMessage(reply_to, msg) -> {
      // Sort plugins by priority (higher first)
      let sorted_entries =
        state.plugins
        |> dict.values()
        |> list.filter(fn(entry) { entry.plugin.enabled })
        |> list.sort(fn(a, b) {
          int.compare(b.plugin.priority, a.plugin.priority)
        })

      // Process message through each plugin with error isolation
      let result = process_plugins_message(sorted_entries, state.plugins, msg)

      case result {
        Ok(new_plugins) -> {
          let new_state =
            RegistryState(
              plugins: new_plugins,
              message_count: state.message_count + 1,
            )
          actor.send(reply_to, Ok(Nil))
          actor.continue(new_state)
        }
        Error(error) -> {
          actor.send(reply_to, Error(error))
          actor.continue(state)
        }
      }
    }

    LoadPlugin(reply_to, name) -> {
      case dict.get(state.plugins, name) {
        Ok(entry) -> {
          // Call on_load with error isolation
          let result = safe_call_on_load(entry.plugin, entry.state)
          case result {
            Ok(new_state) -> {
              let new_entry =
                PluginEntry(..entry, state: new_state, status: Active)
              let new_plugins = dict.insert(state.plugins, name, new_entry)
              let new_state = RegistryState(..state, plugins: new_plugins)
              actor.send(reply_to, Ok(Nil))
              actor.continue(new_state)
            }
            Error(error) -> {
              // Update status to error
              let new_entry =
                PluginEntry(..entry, status: PluginError(reason: error.reason))
              let new_plugins = dict.insert(state.plugins, name, new_entry)
              let new_state = RegistryState(..state, plugins: new_plugins)
              actor.send(reply_to, Error(error))
              actor.continue(new_state)
            }
          }
        }
        Error(_) -> {
          actor.send(
            reply_to,
            Error(PluginNotFound(plugin_name: name, reason: "Plugin not found")),
          )
          actor.continue(state)
        }
      }
    }

    ShutdownPlugin(reply_to, name) -> {
      case dict.get(state.plugins, name) {
        Ok(entry) -> {
          // Call on_shutdown with error isolation
          let _ = safe_call_on_shutdown(entry.plugin, entry.state)
          let new_entry = PluginEntry(..entry, status: Stopped)
          let new_plugins = dict.insert(state.plugins, name, new_entry)
          let new_state = RegistryState(..state, plugins: new_plugins)
          actor.send(reply_to, Ok(Nil))
          actor.continue(new_state)
        }
        Error(_) -> {
          actor.send(
            reply_to,
            Error(PluginNotFound(plugin_name: name, reason: "Plugin not found")),
          )
          actor.continue(state)
        }
      }
    }

    ShutdownAll(reply_to) -> {
      // Shutdown all plugins
      state.plugins
      |> dict.values()
      |> list.each(fn(entry) {
        let _ = safe_call_on_shutdown(entry.plugin, entry.state)
        Nil
      })

      actor.send(reply_to, Nil)
      actor.stop()
    }

    GetPluginStatus(reply_to, name) -> {
      let result = case dict.get(state.plugins, name) {
        Ok(entry) -> Some(entry.status)
        Error(_) -> None
      }
      actor.send(reply_to, result)
      actor.continue(state)
    }

    StopRegistry(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

/// Process message through all plugins with error isolation
fn process_plugins_message(
  entries: List(PluginEntry),
  plugins: Dict(String, PluginEntry),
  msg: PluginMessage,
) -> Result(Dict(String, PluginEntry), PluginError) {
  case entries {
    [] -> Ok(plugins)
    [first, ..rest] -> {
      // Call on_message with error isolation
      let result = safe_call_on_message(first.plugin, first.state, msg)
      case result {
        Ok(new_state) -> {
          // Update plugin state
          let new_entry = PluginEntry(..first, state: new_state)
          let new_plugins = dict.insert(plugins, first.plugin.name, new_entry)
          // Continue with rest
          process_plugins_message(rest, new_plugins, msg)
        }
        Error(error) -> {
          // Update status to error but continue processing other plugins
          let new_entry =
            PluginEntry(..first, status: PluginError(reason: error.reason))
          let new_plugins = dict.insert(plugins, first.plugin.name, new_entry)
          // Continue with rest - error isolation
          process_plugins_message(rest, new_plugins, msg)
        }
      }
    }
  }
}

/// Safely call on_load with error isolation
fn safe_call_on_load(
  plugin: Plugin,
  state: PluginState,
) -> Result(PluginState, PluginError) {
  let result = plugin.on_load(state)
  case result {
    PluginOk(new_state) -> Ok(new_state)
    PluginErr(error) -> Error(error)
  }
}

/// Safely call on_message with error isolation
fn safe_call_on_message(
  plugin: Plugin,
  state: PluginState,
  msg: PluginMessage,
) -> Result(PluginState, PluginError) {
  let result = plugin.on_message(state, msg)
  case result {
    PluginOk(new_state) -> Ok(new_state)
    PluginErr(error) -> Error(error)
  }
}

/// Safely call on_shutdown (always returns Nil, errors are swallowed)
fn safe_call_on_shutdown(plugin: Plugin, state: PluginState) -> Nil {
  let _ = plugin.on_shutdown(state)
  Nil
}

// ============================================================================
// Public Registry API
// ============================================================================

/// Start a new plugin registry
pub fn start_registry() -> Result(PluginRegistry, actor.StartError) {
  let initial_state = RegistryState(plugins: dict.new(), message_count: 0)

  case
    actor.new(initial_state)
    |> actor.on_message(handle_registry_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Register a plugin with the registry
pub fn register(
  registry: PluginRegistry,
  plugin: Plugin,
) -> Result(Nil, PluginError) {
  let reply_subject = process.new_subject()
  actor.send(registry, RegisterPlugin(reply_subject, plugin))
  case process.receive(reply_subject, 5000) {
    Ok(result) -> result
    Error(_) -> Error(LoadError(plugin_name: plugin.name, reason: "Timeout"))
  }
}

/// Unregister a plugin from the registry
pub fn unregister(
  registry: PluginRegistry,
  name: String,
) -> Result(Nil, PluginError) {
  let reply_subject = process.new_subject()
  actor.send(registry, UnregisterPlugin(reply_subject, name))
  case process.receive(reply_subject, 5000) {
    Ok(result) -> result
    Error(_) -> Error(PluginNotFound(plugin_name: name, reason: "Timeout"))
  }
}

/// Get a plugin by name
pub fn get_plugin(registry: PluginRegistry, name: String) -> Option(Plugin) {
  actor.call(registry, waiting: 1000, sending: GetPlugin(_, name))
}

/// List all registered plugins
pub fn list_plugins(registry: PluginRegistry) -> List(Plugin) {
  actor.call(registry, waiting: 1000, sending: ListPlugins)
}

/// Notify all plugins of a message
pub fn notify_message(
  registry: PluginRegistry,
  message: PluginMessage,
) -> Result(Nil, PluginError) {
  let reply_subject = process.new_subject()
  actor.send(registry, NotifyMessage(reply_subject, message))
  case process.receive(reply_subject, 5000) {
    Ok(result) -> result
    Error(_) -> Error(MessageError(plugin_name: "registry", reason: "Timeout"))
  }
}

/// Load a plugin (call on_load)
pub fn load_plugin(
  registry: PluginRegistry,
  name: String,
) -> Result(Nil, PluginError) {
  let reply_subject = process.new_subject()
  actor.send(registry, LoadPlugin(reply_subject, name))
  case process.receive(reply_subject, 5000) {
    Ok(result) -> result
    Error(_) -> Error(LoadError(plugin_name: name, reason: "Timeout"))
  }
}

/// Shutdown a specific plugin
pub fn shutdown_plugin(
  registry: PluginRegistry,
  name: String,
) -> Result(Nil, PluginError) {
  let reply_subject = process.new_subject()
  actor.send(registry, ShutdownPlugin(reply_subject, name))
  case process.receive(reply_subject, 5000) {
    Ok(result) -> result
    Error(_) -> Error(ShutdownError(plugin_name: name, reason: "Timeout"))
  }
}

/// Shutdown all plugins
pub fn shutdown_all(registry: PluginRegistry) -> Nil {
  actor.call(registry, waiting: 5000, sending: ShutdownAll)
}

/// Get plugin status
pub fn get_plugin_status(
  registry: PluginRegistry,
  name: String,
) -> Option(PluginStatus) {
  actor.call(registry, waiting: 1000, sending: GetPluginStatus(_, name))
}

/// Stop the registry
pub fn stop_registry(registry: PluginRegistry) -> Nil {
  actor.call(registry, waiting: 1000, sending: StopRegistry)
}

// ============================================================================
// Plugin Configuration Parsing
// ============================================================================

/// Parse plugin configuration from YAML string
pub fn parse_config_yaml(
  yaml: String,
) -> Result(PluginsConfigFile, ConfigParseError) {
  let rescued = exception.rescue(fn() { do_parse_config_yaml(yaml) })
  case rescued {
    Error(_) -> Error(YamlParseError(message: "Unexpected parsing error"))
    Ok(result) -> result
  }
}

fn do_parse_config_yaml(
  yaml: String,
) -> Result(PluginsConfigFile, ConfigParseError) {
  case yay.parse_string(string.trim(yaml)) {
    Ok([doc]) -> {
      let root = yay.document_root(doc)
      // Try to get plugins list
      case yay.select_sugar(root, "plugins") {
        Ok(plugins_node) -> {
          // Parse each plugin config
          let plugin_configs = parse_plugins_list(plugins_node)
          Ok(PluginsConfigFile(plugins: plugin_configs))
        }
        Error(_) -> {
          // No plugins field, return empty config
          Ok(PluginsConfigFile(plugins: []))
        }
      }
    }
    Ok([]) -> {
      // Empty YAML, return empty config
      Ok(PluginsConfigFile(plugins: []))
    }
    Ok(docs) ->
      Error(YamlParseError(
        message: "Expected 1 YAML document, got "
        <> int.to_string(list.length(docs)),
      ))
    Error(error) -> {
      // Handle all YAML error types
      let msg = case error {
        yay.UnexpectedParsingError -> "Unexpected parsing error"
        yay.ParsingError(m, loc) -> {
          let yay.YamlErrorLoc(line: line, column: column) = loc
          m
          <> " at line "
          <> int.to_string(line)
          <> ", column "
          <> int.to_string(column)
        }
      }
      Error(YamlParseError(message: msg))
    }
  }
}

/// Parse list of plugins from YAML node
fn parse_plugins_list(node: yay.Node) -> List(PluginConfig) {
  case node {
    yay.NodeSeq(items) -> {
      items
      |> list.filter_map(fn(item) {
        case item {
          yay.NodeMap(fields) -> {
            let name = get_string_from_node_map(fields, "name")
            let enabled = get_bool_from_node_map(fields, "enabled")
            let config = get_config_dict_from_node_map(fields)

            case name {
              Some(n) ->
                Ok(PluginConfig(name: n, enabled: enabled, config: config))
              None -> Error(Nil)
            }
          }
          _ -> Error(Nil)
        }
      })
    }
    _ -> []
  }
}

/// Convert node key to string
fn node_key_to_string(node: yay.Node) -> Option(String) {
  case node {
    yay.NodeStr(s) -> Some(s)
    _ -> None
  }
}

/// Get string value from node map (keys are nodes too)
fn get_string_from_node_map(
  fields: List(#(yay.Node, yay.Node)),
  key: String,
) -> Option(String) {
  case
    list.find(fields, fn(pair) {
      let #(key_node, _) = pair
      case node_key_to_string(key_node) {
        Some(k) -> k == key
        None -> False
      }
    })
  {
    Ok(pair) -> {
      let #(_, value_node) = pair
      case value_node {
        yay.NodeStr(value) -> Some(value)
        _ -> None
      }
    }
    Error(_) -> None
  }
}

/// Get bool value from node map
fn get_bool_from_node_map(
  fields: List(#(yay.Node, yay.Node)),
  key: String,
) -> Bool {
  case
    list.find(fields, fn(pair) {
      let #(key_node, _) = pair
      case node_key_to_string(key_node) {
        Some(k) -> k == key
        None -> False
      }
    })
  {
    Ok(pair) -> {
      let #(_, value_node) = pair
      case value_node {
        yay.NodeBool(value) -> value
        _ -> True
      }
    }
    Error(_) -> True
  }
}

/// Get config dict from node map
fn get_config_dict_from_node_map(
  fields: List(#(yay.Node, yay.Node)),
) -> Dict(String, String) {
  case
    list.find(fields, fn(pair) {
      let #(key_node, _) = pair
      case node_key_to_string(key_node) {
        Some(k) -> k == "config"
        None -> False
      }
    })
  {
    Ok(pair) -> {
      let #(_, config_node) = pair
      case config_node {
        yay.NodeMap(config_fields) -> {
          config_fields
          |> list.filter_map(fn(pair) {
            let #(key_node, value_node) = pair
            case node_key_to_string(key_node) {
              Some(key) -> {
                case value_node {
                  yay.NodeStr(value) -> Ok(#(key, value))
                  yay.NodeInt(value) -> Ok(#(key, int.to_string(value)))
                  yay.NodeFloat(value) -> Ok(#(key, float_to_string(value)))
                  yay.NodeBool(value) -> Ok(#(key, bool_to_string(value)))
                  _ -> Error(Nil)
                }
              }
              None -> Error(Nil)
            }
          })
          |> dict.from_list()
        }
        _ -> dict.new()
      }
    }
    Error(_) -> dict.new()
  }
}

/// Parse plugin configuration from JSON string
pub fn parse_config_json(
  json_str: String,
) -> Result(PluginsConfigFile, ConfigParseError) {
  let decoder = decode_plugins_config()
  case json.parse(from: json_str, using: decoder) {
    Ok(config) -> Ok(config)
    Error(_) -> Error(JsonParseError(message: "Failed to parse JSON"))
  }
}

/// Decode plugins config from JSON
fn decode_plugins_config() -> decode.Decoder(PluginsConfigFile) {
  use plugins <- decode.optional_field(
    "plugins",
    [],
    decode.list(decode_plugin_config()),
  )
  decode.success(PluginsConfigFile(plugins: plugins))
}

/// Decode a single plugin config from JSON
fn decode_plugin_config() -> decode.Decoder(PluginConfig) {
  use name <- decode.field("name", decode.string)
  use enabled <- decode.field("enabled", decode.optional(decode.bool))
  // For JSON, we only support basic name/enabled - config requires dynamic decoding
  // which is complex. Users should use YAML for full config support.
  decode.success(PluginConfig(
    name: name,
    enabled: option.unwrap(enabled, True),
    config: dict.new(),
  ))
}

/// Convert plugin config to plugin state
pub fn config_to_state(config: PluginConfig) -> PluginState {
  PluginState(config: config.config, data: dict.new())
}

/// Serialize plugin config to JSON string
pub fn serialize_config(config: PluginConfig) -> String {
  let config_json =
    config.config
    |> dict.to_list()
    |> list.map(fn(pair) {
      let #(key, value) = pair
      json_object_pair(key, json_string(value))
    })
    |> string.join(",")

  let enabled_str = bool_to_string(config.enabled)
  "{\"name\":\""
  <> config.name
  <> "\",\"enabled\":"
  <> enabled_str
  <> ",\"config\":{"
  <> config_json
  <> "}}"
}

/// Serialize plugins config file to JSON
pub fn serialize_config_file(config: PluginsConfigFile) -> String {
  let plugins_json =
    config.plugins
    |> list.map(serialize_config)
    |> string.join(",")

  "{\"plugins\":[" <> plugins_json <> "]}"
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Format plugin status to string
pub fn format_status(status: PluginStatus) -> String {
  case status {
    Loaded -> "loaded"
    Active -> "active"
    PluginError(reason) -> "error: " <> reason
    Stopped -> "stopped"
  }
}

/// Format plugin error to string
pub fn format_error(error: PluginError) -> String {
  case error {
    LoadError(plugin_name, reason) ->
      "LoadError[" <> plugin_name <> "]: " <> reason
    MessageError(plugin_name, reason) ->
      "MessageError[" <> plugin_name <> "]: " <> reason
    ShutdownError(plugin_name, reason) ->
      "ShutdownError[" <> plugin_name <> "]: " <> reason
    PluginNotFound(plugin_name, reason) ->
      "PluginNotFound[" <> plugin_name <> "]: " <> reason
    PluginAlreadyRegistered(plugin_name, reason) ->
      "PluginAlreadyRegistered[" <> plugin_name <> "]: " <> reason
    InvalidConfig(plugin_name, reason) ->
      "InvalidConfig[" <> plugin_name <> "]: " <> reason
  }
}

/// Check if plugin result is ok
pub fn is_ok(result: PluginResult(a)) -> Bool {
  case result {
    PluginOk(_) -> True
    PluginErr(_) -> False
  }
}

/// Check if plugin result is error
pub fn is_err(result: PluginResult(a)) -> Bool {
  case result {
    PluginOk(_) -> False
    PluginErr(_) -> True
  }
}

/// Unwrap plugin result value (panics on error)
pub fn plugin_unwrap(result: PluginResult(a)) -> a {
  case result {
    PluginOk(value) -> value
    PluginErr(error) -> {
      let msg = "unwrap called on PluginErr: " <> format_error(error)
      panic as msg
    }
  }
}

/// Unwrap plugin result with default
pub fn plugin_unwrap_or(result: PluginResult(a), default: a) -> a {
  case result {
    PluginOk(value) -> value
    PluginErr(_) -> default
  }
}

// ============================================================================
// JSON Helpers (internal)
// ============================================================================

fn json_string(value: String) -> String {
  "\"" <> escape_json_string(value) <> "\""
}

fn json_object_pair(key: String, value: String) -> String {
  "\"" <> key <> "\":" <> value
}

fn escape_json_string(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

fn bool_to_string(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

fn float_to_string(f: Float) -> String {
  // Convert float to string representation
  let truncated = float.truncate(f)
  let diff = float.absolute_value(f -. int.to_float(truncated))
  case diff <. 0.0001 {
    True -> int.to_string(truncated)
    False -> {
      // Simple float to string - just use inspect for now
      string.inspect(f)
    }
  }
}
