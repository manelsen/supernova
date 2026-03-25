//// MCP Config Loader — loads MCP server configurations from YAML.
////
//// Parses supernova.yaml to extract MCP server definitions.

import gleam/option.{type Option, None}
import supernova/adapters/mcp_manager
import supernova/llm/provider

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
  // Simple line-based parser for MCP server configs
  // In production, use a proper YAML parser
  parse_server_blocks(yaml_content, [], None)
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
  _content: String,
  acc: List(mcp_manager.ServerConfig),
  _current: Option(String),
) -> List(mcp_manager.ServerConfig) {
  // Simplified: just return empty for now
  // Real implementation would parse YAML structure
  acc
}
