//// MCP Manager — manages multiple MCP server connections.
////
//// Provides unified tool discovery and execution across multiple MCP servers.
//// Each server is configured with a command and args, and the manager handles
//// lifecycle, tool discovery, and routing via real JSON-RPC 2.0 over STDIO.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(mgr) = mcp_manager.start()
//// let config = mcp_manager.ServerConfig(name: "fs", command: "npx", args: [...], env: [])
//// mcp_manager.register(mgr, config)
//// ```

import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/otp/actor
import gleam/string
import supernova/adapters/mcp/stdio.{type StdioError, type StdioTransport}
import supernova/llm/provider

// ============================================================================
// Types
// ============================================================================

/// Configuration for an MCP server.
pub type ServerConfig {
  ServerConfig(
    /// Unique name for this server
    name: String,
    /// Command to execute (e.g., "npx", "node", "python")
    command: String,
    /// Command arguments
    args: List(String),
    /// Environment variables
    env: List(#(String, String)),
  )
}

/// A discovered tool from an MCP server.
pub type MCPTool {
  MCPTool(
    /// Tool definition (for LLM). spec.name is qualified: "server_name/tool_name"
    spec: provider.ToolDefinition,
    /// Which server provides this tool
    server_name: String,
    /// Original tool name as declared by the MCP server (unqualified)
    original_name: String,
  )
}

/// An active MCP server connection.
type ServerConnection {
  ServerConnection(
    config: ServerConfig,
    transport: StdioTransport,
    initialized: Bool,
    request_id: Int,
  )
}

/// Messages for the manager actor.
pub type ManagerMessage {
  RegisterServer(reply_to: Subject(Result(Nil, String)), config: ServerConfig)
  UnregisterServer(reply_to: Subject(Result(Nil, String)), name: String)
  ListServers(reply_to: Subject(List(String)))
  GetServerConfig(reply_to: Subject(Result(ServerConfig, String)), name: String)
  ListTools(reply_to: Subject(List(MCPTool)))
  ExecuteTool(
    reply_to: Subject(Result(String, String)),
    tool_name: String,
    args: String,
  )
  Stop(reply_to: Subject(Nil))
}

/// Manager state.
type ManagerState {
  ManagerState(
    servers: Dict(String, ServerConnection),
    tools: Dict(String, MCPTool),
  )
}

/// Classification of tools/call failures so transport loss and JSON-RPC
/// application errors are handled distinctly.
type ToolsCallFailure {
  DeadTransportError(String)
  TransientTransportError(String)
  ProtocolError(String)
}

/// The manager handle.
pub type MCPManager =
  Subject(ManagerMessage)

// ============================================================================
// JSON-RPC 2.0 Helpers
// ============================================================================

/// Build a JSON-RPC 2.0 request string.
/// Uses string concatenation to include pre-encoded params.
fn jsonrpc_request(id: Int, method: String, params: String) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":"
  <> int.to_string(id)
  <> ",\"method\":\""
  <> json_escape(method)
  <> "\",\"params\":"
  <> params
  <> "}"
}

/// Build a JSON-RPC 2.0 notification string (no id).
fn jsonrpc_notification(method: String, params: String) -> String {
  "{\"jsonrpc\":\"2.0\",\"method\":\""
  <> json_escape(method)
  <> "\",\"params\":"
  <> params
  <> "}"
}

/// Escape a string for JSON.
fn json_escape(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

// ============================================================================
// MCP Protocol: Initialize
// ============================================================================

/// Build the initialize request params.
fn initialize_params() -> String {
  "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"supernova\",\"version\":\"1.0.0\"}}"
}

fn supported_protocol_versions() -> List(String) {
  ["2024-11-05"]
}

fn protocol_version_decoder() -> decode.Decoder(String) {
  use version <- decode.field("protocolVersion", decode.string)
  decode.success(version)
}

fn validate_protocol_version(result_json: String) -> Result(Nil, String) {
  case json.parse(result_json, protocol_version_decoder()) {
    Ok(version) ->
      case list.contains(supported_protocol_versions(), version) {
        True -> Ok(Nil)
        False -> Error("Unsupported MCP protocol version: " <> version)
      }
    Error(_) -> Error("Missing protocolVersion in initialize response")
  }
}

/// Send a JSON-RPC request and drain lines inside the stdio transport until a
/// response with matching `id` arrives or the timeout expires. Non-JSON lines
/// are accepted immediately so the parser reports invalid responses without blocking.
fn send_request_matching_id(
  transport: StdioTransport,
  expected_id: Int,
  request: String,
  timeout_ms: Int,
) -> Result(String, StdioError) {
  stdio.send_and_receive_matching(transport, request, timeout_ms, fn(line) {
    matches_expected_id_or_non_json(line, expected_id)
  })
}

fn matches_expected_id_or_non_json(line: String, expected_id: Int) -> Bool {
  case json.parse(line, decode.dynamic) {
    Error(_) -> True
    Ok(_) ->
      case json.parse(line, decode.at(["id"], decode.int)) {
        Ok(resp_id) -> resp_id == expected_id
        Error(_) -> False
      }
  }
}

/// Send the initialize handshake to an MCP server.
fn send_initialize(transport: StdioTransport, id: Int) -> Result(Nil, String) {
  let request = jsonrpc_request(id, "initialize", initialize_params())
  case send_request_matching_id(transport, id, request, 10_000) {
    Ok(response) -> {
      case parse_jsonrpc_result(response) {
        Ok(result_json) -> {
          case validate_protocol_version(result_json) {
            Error(e) -> Error(e)
            Ok(_) -> {
              let notification =
                jsonrpc_notification("notifications/initialized", "{}")
              case stdio.send_only(transport, notification) {
                Ok(_) -> Ok(Nil)
                Error(e) -> Error("Failed to send initialized: " <> e)
              }
            }
          }
        }
        Error(e) -> Error("Initialize failed: " <> e)
      }
    }
    Error(e) -> Error("Initialize timeout/error: " <> stdio.error_to_string(e))
  }
}

// ============================================================================
// MCP Protocol: Tools List
// ============================================================================

/// Send tools/list request and parse the response.
fn send_tools_list(
  transport: StdioTransport,
  id: Int,
  server_name: String,
) -> Result(List(MCPTool), String) {
  let request = jsonrpc_request(id, "tools/list", "{}")
  case send_request_matching_id(transport, id, request, 10_000) {
    Ok(response) -> {
      case parse_jsonrpc_result(response) {
        Ok(result_json) -> parse_tools_response(result_json, server_name)
        Error(e) -> Error("tools/list failed: " <> e)
      }
    }
    Error(e) -> Error("tools/list timeout/error: " <> stdio.error_to_string(e))
  }
}

/// Parse the tools/list response into MCPTool list.
fn parse_tools_response(
  raw: String,
  server_name: String,
) -> Result(List(MCPTool), String) {
  case json.parse(raw, tools_list_decoder(server_name)) {
    Ok(tools) -> Ok(tools)
    Error(_) -> {
      // If parsing fails, try empty tools
      Ok([])
    }
  }
}

/// Decoder for tools/list response.
fn tools_list_decoder(server_name: String) -> decode.Decoder(List(MCPTool)) {
  use tools <- decode.field("tools", decode.list(tool_decoder(server_name)))
  decode.success(tools)
}

/// Decoder for a single tool in the tools/list response.
fn tool_decoder(server_name: String) -> decode.Decoder(MCPTool) {
  use name <- decode.field("name", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  // The full argument schema goes to the model (PRD-S, S-01, S-02).
  use input_schema <- decode.optional_field(
    "inputSchema",
    None,
    decode.dynamic |> decode.map(Some),
  )
  let qualified_name = server_name <> "/" <> name
  let spec =
    provider.ToolDefinition(
      name: qualified_name,
      description: description,
      parameters: [],
      schema: option.map(input_schema, fn(value) {
        json.to_string(provider.dynamic_json(value))
      }),
    )
  decode.success(MCPTool(
    spec: spec,
    server_name: server_name,
    original_name: name,
  ))
}

// ============================================================================
// MCP Protocol: Tools Call
// ============================================================================

/// Send tools/call request and return the result or classified failure.
fn send_tools_call(
  transport: StdioTransport,
  id: Int,
  tool_name: String,
  args: String,
) -> Result(String, ToolsCallFailure) {
  let params =
    "{\"name\":\""
    <> json_escape(tool_name)
    <> "\",\"arguments\":"
    <> args
    <> "}"

  let request = jsonrpc_request(id, "tools/call", params)
  case send_request_matching_id(transport, id, request, 30_000) {
    Ok(response) -> {
      case parse_jsonrpc_result(response) {
        Ok(result_json) -> Ok(result_json)
        Error(e) -> Error(ProtocolError("tools/call failed: " <> e))
      }
    }
    Error(stdio.ProcessDead(msg)) ->
      Error(DeadTransportError("tools/call timeout/error: " <> msg))
    Error(stdio.Timeout(msg)) | Error(stdio.OtherError(msg)) ->
      Error(TransientTransportError("tools/call timeout/error: " <> msg))
  }
}

// ============================================================================
// JSON-RPC Response Parsing
// ============================================================================

/// Parse a JSON-RPC 2.0 response and extract the result field.
fn parse_jsonrpc_result(response: String) -> Result(String, String) {
  // Check if response has an error field
  case json.parse(response, has_error_decoder()) {
    Ok(True) -> {
      case json.parse(response, error_message_decoder()) {
        Ok(msg) -> Error(msg)
        Error(_) -> Error("JSON-RPC error in response")
      }
    }
    _ -> {
      // Try to extract result
      case json.parse(response, result_decoder()) {
        Ok(result_str) -> Ok(result_str)
        Error(_) -> Error("Invalid JSON-RPC response: " <> response)
      }
    }
  }
}

/// Check if response has an error field.
fn has_error_decoder() -> decode.Decoder(Bool) {
  use has_error <- decode.optional_field("error", False, decode.success(True))
  decode.success(has_error)
}

/// Extract error message from JSON-RPC error response.
fn error_message_decoder() -> decode.Decoder(String) {
  use error <- decode.field("error", error_obj_decoder())
  decode.success(error)
}

fn error_obj_decoder() -> decode.Decoder(String) {
  use message <- decode.field("message", decode.string)
  decode.success(message)
}

@external(erlang, "supernova_mcp_ffi", "dynamic_to_json")
fn dynamic_to_json(value: dynamic.Dynamic) -> Result(String, String)

/// Extract result from JSON-RPC success response as a JSON string.
fn result_decoder() -> decode.Decoder(String) {
  use result_val <- decode.field("result", decode.dynamic)
  case dynamic_to_json(result_val) {
    Ok(json_str) -> decode.success(json_str)
    Error(e) -> decode.failure("result", "Could not encode to JSON: " <> e)
  }
}

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: ManagerState,
  message: ManagerMessage,
) -> actor.Next(ManagerState, ManagerMessage) {
  case message {
    RegisterServer(reply_to, config) -> {
      case dict.get(state.servers, config.name) {
        Ok(_) -> {
          actor.send(
            reply_to,
            Error("Server already registered: " <> config.name),
          )
          actor.continue(state)
        }
        Error(_) -> {
          // Start the STDIO transport
          case stdio.start(config.command, config.args, config.env) {
            Ok(transport) -> {
              // Send initialize handshake
              case send_initialize(transport, 1) {
                Ok(_) -> {
                  // Discover tools
                  let tools_result = send_tools_list(transport, 2, config.name)
                  let tools = case tools_result {
                    Ok(discovered) -> discovered
                    Error(_) -> []
                  }

                  // Build server connection
                  let connection =
                    ServerConnection(
                      config: config,
                      transport: transport,
                      initialized: True,
                      request_id: 3,
                    )

                  // Update state
                  let new_servers =
                    dict.insert(state.servers, config.name, connection)
                  let new_tools =
                    list.fold(tools, state.tools, fn(acc, tool) {
                      dict.insert(acc, tool.spec.name, tool)
                    })

                  actor.send(reply_to, Ok(Nil))
                  actor.continue(ManagerState(
                    servers: new_servers,
                    tools: new_tools,
                  ))
                }
                Error(e) -> {
                  // Clean up transport on init failure
                  stdio.stop(transport)
                  actor.send(
                    reply_to,
                    Error("Failed to initialize " <> config.name <> ": " <> e),
                  )
                  actor.continue(state)
                }
              }
            }
            Error(e) -> {
              actor.send(
                reply_to,
                Error("Failed to start " <> config.name <> ": " <> e),
              )
              actor.continue(state)
            }
          }
        }
      }
    }

    UnregisterServer(reply_to, name) -> {
      case dict.get(state.servers, name) {
        Ok(connection) -> {
          // Stop the transport
          stdio.stop(connection.transport)

          // Remove from state
          let new_servers = dict.delete(state.servers, name)
          // Remove tools from this server
          let new_tools =
            dict.filter(state.tools, fn(_key, tool) { tool.server_name != name })

          actor.send(reply_to, Ok(Nil))
          actor.continue(ManagerState(servers: new_servers, tools: new_tools))
        }
        Error(_) -> {
          actor.send(reply_to, Error("Server not found: " <> name))
          actor.continue(state)
        }
      }
    }

    ListServers(reply_to) -> {
      let names =
        state.servers
        |> dict.keys
        |> list.sort(string_compare)
      actor.send(reply_to, names)
      actor.continue(state)
    }

    GetServerConfig(reply_to, name) -> {
      case dict.get(state.servers, name) {
        Ok(connection) -> {
          actor.send(reply_to, Ok(connection.config))
          actor.continue(state)
        }
        Error(_) -> {
          actor.send(reply_to, Error("Server not found: " <> name))
          actor.continue(state)
        }
      }
    }

    ListTools(reply_to) -> {
      let tools =
        state.tools
        |> dict.values
      actor.send(reply_to, tools)
      actor.continue(state)
    }

    ExecuteTool(reply_to, tool_name, args) -> {
      case dict.get(state.tools, tool_name) {
        Ok(mcp_tool) -> {
          case dict.get(state.servers, mcp_tool.server_name) {
            Ok(connection) -> {
              let id = connection.request_id
              let result =
                send_tools_call(
                  connection.transport,
                  id,
                  mcp_tool.original_name,
                  args,
                )

              case result {
                Ok(output) -> {
                  let new_state =
                    advance_request_id(state, mcp_tool.server_name, connection)
                  actor.send(reply_to, Ok(output))
                  actor.continue(new_state)
                }
                Error(DeadTransportError(e)) -> {
                  let new_state = evict_dead_server(state, mcp_tool.server_name)
                  actor.send(reply_to, Error(e))
                  actor.continue(new_state)
                }
                Error(TransientTransportError(e)) | Error(ProtocolError(e)) -> {
                  let new_state =
                    advance_request_id(state, mcp_tool.server_name, connection)
                  actor.send(reply_to, Error(e))
                  actor.continue(new_state)
                }
              }
            }
            Error(_) -> {
              actor.send(
                reply_to,
                Error("Server not found for tool: " <> mcp_tool.server_name),
              )
              actor.continue(state)
            }
          }
        }
        Error(_) -> {
          actor.send(reply_to, Error("Tool not found: " <> tool_name))
          actor.continue(state)
        }
      }
    }

    Stop(reply_to) -> {
      // Stop all server connections
      dict.each(state.servers, fn(_key, connection) {
        stdio.stop(connection.transport)
      })
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

fn string_compare(a: String, b: String) -> order.Order {
  string.compare(a, b)
}

fn advance_request_id(
  state: ManagerState,
  server_name: String,
  connection: ServerConnection,
) -> ManagerState {
  let updated_connection =
    ServerConnection(..connection, request_id: connection.request_id + 1)
  let new_servers = dict.insert(state.servers, server_name, updated_connection)
  ManagerState(..state, servers: new_servers)
}

fn evict_dead_server(state: ManagerState, server_name: String) -> ManagerState {
  case dict.get(state.servers, server_name) {
    Ok(connection) -> stdio.stop(connection.transport)
    Error(_) -> Nil
  }
  let new_servers = dict.delete(state.servers, server_name)
  let new_tools =
    dict.filter(state.tools, fn(_k, t) { t.server_name != server_name })
  ManagerState(servers: new_servers, tools: new_tools)
}

// ============================================================================
// Public API
// ============================================================================

/// Start a new MCP manager.
pub fn start() -> Result(MCPManager, actor.StartError) {
  let initial_state = ManagerState(servers: dict.new(), tools: dict.new())

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(reason) -> Error(reason)
  }
}

/// Register an MCP server configuration.
/// This starts the server process, performs the MCP initialize handshake,
/// and discovers available tools.
pub fn register(
  manager: MCPManager,
  config: ServerConfig,
) -> Result(Nil, String) {
  actor.call(manager, waiting: 30_000, sending: RegisterServer(_, config))
}

/// Unregister an MCP server and stop its process.
pub fn unregister(manager: MCPManager, name: String) -> Result(Nil, String) {
  actor.call(manager, waiting: 10_000, sending: UnregisterServer(_, name))
}

/// List all registered server names.
pub fn list_servers(manager: MCPManager) -> List(String) {
  actor.call(manager, waiting: 5000, sending: ListServers)
}

/// Get a server's configuration by name.
pub fn get_server(
  manager: MCPManager,
  name: String,
) -> Result(ServerConfig, String) {
  actor.call(manager, waiting: 5000, sending: GetServerConfig(_, name))
}

/// List all discovered tools across all servers.
pub fn list_tools(manager: MCPManager) -> List(MCPTool) {
  actor.call(manager, waiting: 5000, sending: ListTools)
}

/// Execute a tool by name with JSON arguments.
pub fn execute_tool(
  manager: MCPManager,
  tool_name: String,
  args: String,
) -> Result(String, String) {
  actor.call(manager, waiting: 30_000, sending: ExecuteTool(_, tool_name, args))
}

/// Stop the manager and all server connections.
pub fn stop(manager: MCPManager) -> Nil {
  actor.call(manager, waiting: 10_000, sending: Stop)
}
