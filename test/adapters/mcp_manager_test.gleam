//// Tests for MCP Manager with real MCP protocol.
////
//// Verifies multi-server management, tool discovery, and routing
//// using a mock MCP server over real STDIO transport.

import gleam/list
import gleam/string
import gleeunit/should
import supernova/adapters/mcp_manager

// ============================================================================
// Basic Manager Tests
// ============================================================================

pub fn start_manager_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let servers = mcp_manager.list_servers(mgr)
  servers
  |> should.equal([])

  mcp_manager.stop(mgr)
}

// ============================================================================
// Server Registration Tests (with mock MCP server)
// ============================================================================

pub fn register_mock_server_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let config =
    mcp_manager.ServerConfig(
      name: "mock-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = mcp_manager.register(mgr, config)

  let servers = mcp_manager.list_servers(mgr)
  servers
  |> should.equal(["mock-server"])

  mcp_manager.stop(mgr)
}

pub fn register_duplicate_server_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let config =
    mcp_manager.ServerConfig(
      name: "dup",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = mcp_manager.register(mgr, config)
  let result = mcp_manager.register(mgr, config)
  result
  |> should.be_error

  mcp_manager.stop(mgr)
}

pub fn register_invalid_command_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let config =
    mcp_manager.ServerConfig(
      name: "invalid",
      command: "nonexistent_command_xyz",
      args: [],
      env: [],
    )

  let result = mcp_manager.register(mgr, config)
  result
  |> should.be_error

  mcp_manager.stop(mgr)
}

pub fn get_server_config_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let config =
    mcp_manager.ServerConfig(
      name: "my-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = mcp_manager.register(mgr, config)

  let result = mcp_manager.get_server(mgr, "my-server")
  case result {
    Ok(cfg) -> {
      cfg.command
      |> should.equal("python3")
    }
    Error(_) -> should.fail()
  }

  mcp_manager.stop(mgr)
}

pub fn get_nonexistent_server_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let result = mcp_manager.get_server(mgr, "nope")
  result
  |> should.be_error

  mcp_manager.stop(mgr)
}

// ============================================================================
// Tool Discovery Tests
// ============================================================================

pub fn discover_tools_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let config =
    mcp_manager.ServerConfig(
      name: "tool-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = mcp_manager.register(mgr, config)

  let tools = mcp_manager.list_tools(mgr)
  // Mock server provides "echo" and "add" tools
  tools
  |> list.length
  |> should.equal(2)

  // Check tool names
  let tool_names =
    tools
    |> list.map(fn(t) { t.spec.name })
    |> list.sort(string.compare)

  tool_names
  |> should.equal(["add", "echo"])

  mcp_manager.stop(mgr)
}

// ============================================================================
// Tool Execution Tests
// ============================================================================

pub fn execute_echo_tool_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let config =
    mcp_manager.ServerConfig(
      name: "exec-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = mcp_manager.register(mgr, config)

  let result = mcp_manager.execute_tool(mgr, "echo", "{\"message\":\"test\"}")
  case result {
    Ok(response) -> {
      response
      |> string.contains("test")
      |> should.equal(True)
    }
    Error(e) -> {
      let _ = e
      should.fail()
    }
  }

  mcp_manager.stop(mgr)
}

pub fn execute_nonexistent_tool_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let config =
    mcp_manager.ServerConfig(
      name: "exec-server2",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = mcp_manager.register(mgr, config)

  let result = mcp_manager.execute_tool(mgr, "nonexistent", "{}")
  result
  |> should.be_error

  mcp_manager.stop(mgr)
}

// ============================================================================
// Unregister Tests
// ============================================================================

pub fn unregister_server_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let config =
    mcp_manager.ServerConfig(
      name: "temp-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = mcp_manager.register(mgr, config)

  // Verify server is registered
  mcp_manager.list_servers(mgr)
  |> should.equal(["temp-server"])

  // Unregister
  let assert Ok(Nil) = mcp_manager.unregister(mgr, "temp-server")

  // Verify server is gone
  mcp_manager.list_servers(mgr)
  |> should.equal([])

  // Verify tools are gone
  mcp_manager.list_tools(mgr)
  |> should.equal([])

  mcp_manager.stop(mgr)
}

pub fn unregister_nonexistent_server_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let result = mcp_manager.unregister(mgr, "nonexistent")
  result
  |> should.be_error

  mcp_manager.stop(mgr)
}

// ============================================================================
// Multiple Server Tests
// ============================================================================

pub fn multiple_servers_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let config1 =
    mcp_manager.ServerConfig(
      name: "server-1",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let config2 =
    mcp_manager.ServerConfig(
      name: "server-2",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = mcp_manager.register(mgr, config1)
  let assert Ok(Nil) = mcp_manager.register(mgr, config2)

  let servers = mcp_manager.list_servers(mgr)
  servers
  |> should.equal(["server-1", "server-2"])

  // Both servers provide the same tools, but they should be deduplicated
  // or both listed (depending on implementation)
  let tools = mcp_manager.list_tools(mgr)
  let has_tools = case tools {
    [] -> False
    _ -> True
  }
  has_tools |> should.equal(True)

  mcp_manager.stop(mgr)
}
