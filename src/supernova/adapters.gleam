//// Adapters module for Supernova
//// This module contains external system adapters (HTTP, databases, etc.)

import supernova/adapters/mcp_manager

/// Return MCP tools discoverable through the running manager.
pub fn list_mcp_tools(
  manager: mcp_manager.MCPManager,
) -> List(mcp_manager.MCPTool) {
  mcp_manager.list_tools(manager)
}
