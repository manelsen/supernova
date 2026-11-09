//// MCP Config Loader — loads MCP server configurations from YAML.
////
//// Parses supernova.yaml to extract MCP server definitions.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/adapters/mcp_manager
import supernova/llm/provider
import yay

/// Parse MCP server configs from a YAML-like string.
///
/// Expected format:
///   mcp_servers:
///     server-name:
///       command: npx
///       args: ["-y", "server-package"]
///       env:
///         TOKEN: "value"
pub fn parse_servers(yaml_content: String) -> List(mcp_manager.ServerConfig) {
  case yay.parse_string(string.trim(yaml_content)) {
    Ok([doc]) -> {
      let root = yay.document_root(doc)
      parse_server_blocks(root, [], None)
    }
    _ -> []
  }
}

/// Parse MCP server configs from a YAML file path.
pub fn parse_servers_from_file(path: String) -> List(mcp_manager.ServerConfig) {
  case yay.parse_file(path) {
    Ok([doc]) -> {
      let root = yay.document_root(doc)
      parse_server_blocks(root, [], None)
    }
    _ -> []
  }
}

/// Get the tool definition for MCP Config Loader.
pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "mcp_config",
    description: "Load MCP server configurations",
    parameters: [
      provider.string_param("path", "Path to config file", True),
    ],
  )
}

// ============================================================================
// Internal Parser
// ============================================================================

fn parse_server_blocks(
  content: yay.Node,
  acc: List(mcp_manager.ServerConfig),
  current: Option(String),
) -> List(mcp_manager.ServerConfig) {
  let _ = current
  case yay.select_sugar(content, "mcp_servers") {
    Error(_) -> acc
    Ok(yay.NodeMap(server_pairs)) ->
      list.fold(server_pairs, acc, fn(config_acc, pair) {
        let #(server_key, server_node) = pair
        case node_key_to_string(server_key) {
          None -> config_acc
          Some(server_name) ->
            case parse_server_node(server_name, server_node) {
              Ok(server_config) -> [server_config, ..config_acc]
              Error(_) -> config_acc
            }
        }
      })
      |> list.reverse()
    Ok(_) -> acc
  }
}

fn parse_server_node(
  server_name: String,
  node: yay.Node,
) -> Result(mcp_manager.ServerConfig, Nil) {
  use command <- result.try(get_required_string(node, "command"))
  let args = get_string_list(node, "args")
  let env = get_env_map(node, "env")
  Ok(mcp_manager.ServerConfig(
    name: server_name,
    command: command,
    args: args,
    env: env,
  ))
}

fn get_required_string(node: yay.Node, key: String) -> Result(String, Nil) {
  case yay.select_sugar(node, key) {
    Ok(yay.NodeStr(value)) -> Ok(value)
    Ok(yay.NodeInt(value)) -> Ok(int.to_string(value))
    _ -> Error(Nil)
  }
}

fn get_string_list(node: yay.Node, key: String) -> List(String) {
  case yay.select_sugar(node, key) {
    Error(_) -> []
    Ok(yay.NodeSeq(items)) ->
      list.filter_map(items, fn(item) {
        case scalar_node_to_string(item) {
          Some(value) -> Ok(value)
          None -> Error(Nil)
        }
      })
    _ -> []
  }
}

fn get_env_map(node: yay.Node, key: String) -> List(#(String, String)) {
  case yay.select_sugar(node, key) {
    Error(_) -> []
    Ok(yay.NodeMap(fields)) ->
      fields
      |> list.filter_map(fn(pair) {
        let #(k, v) = pair
        case node_key_to_string(k), scalar_node_to_string(v) {
          Some(key), Some(value) -> Ok(#(key, value))
          _, _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

fn scalar_node_to_string(node: yay.Node) -> Option(String) {
  case node {
    yay.NodeStr(value) -> Some(value)
    yay.NodeInt(value) -> Some(int.to_string(value))
    yay.NodeBool(True) -> Some("true")
    yay.NodeBool(False) -> Some("false")
    yay.NodeNil -> Some("")
    yay.NodeMap(_) -> None
    yay.NodeSeq(_) -> None
    _ -> Some(string.inspect(node))
  }
}

fn node_key_to_string(node: yay.Node) -> Option(String) {
  case node {
    yay.NodeStr(value) -> Some(value)
    yay.NodeInt(value) -> Some(int.to_string(value))
    _ -> None
  }
}
