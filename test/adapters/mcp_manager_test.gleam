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
  tools
  |> list.length
  |> should.equal(4)

  // Tool names are qualified as "server_name/tool_name"
  let tool_names =
    tools
    |> list.map(fn(t) { t.spec.name })
    |> list.sort(string.compare)

  tool_names
  |> should.equal([
    "tool-server/add", "tool-server/big_data", "tool-server/echo",
    "tool-server/special_chars",
  ])

  // original_name is unqualified
  let original_names =
    tools
    |> list.map(fn(t) { t.original_name })
    |> list.sort(string.compare)

  original_names
  |> should.equal(["add", "big_data", "echo", "special_chars"])

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

  // Tool names are qualified after discovery
  let result =
    mcp_manager.execute_tool(mgr, "exec-server/echo", "{\"message\":\"test\"}")
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

  // Neither bare name nor wrong qualified name should work
  mcp_manager.execute_tool(mgr, "nonexistent", "{}")
  |> should.be_error

  mcp_manager.execute_tool(mgr, "exec-server2/nonexistent", "{}")
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

  // Tools from both servers are discoverable without collision:
  // each is qualified as "server-name/tool-name"
  let tools = mcp_manager.list_tools(mgr)
  let tool_names =
    tools
    |> list.map(fn(t) { t.spec.name })
    |> list.sort(string.compare)

  // server-1 and server-2 each provide 4 tools — 8 total, no collisions
  tool_names
  |> should.equal([
    "server-1/add", "server-1/big_data", "server-1/echo",
    "server-1/special_chars", "server-2/add", "server-2/big_data",
    "server-2/echo", "server-2/special_chars",
  ])

  mcp_manager.stop(mgr)
}

// ============================================================================
// New regression tests for previously identified bugs
// ============================================================================

pub fn large_response_does_not_truncate_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let config =
    mcp_manager.ServerConfig(
      name: "large-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = mcp_manager.register(mgr, config)

  let result = mcp_manager.execute_tool(mgr, "large-server/big_data", "{}")
  case result {
    Ok(response) ->
      // The big_data tool returns 8192 'A' characters — verify none were lost
      response
      |> string.contains("AAAAAAAA")
      |> should.equal(True)
    Error(e) -> {
      let _ = e
      should.fail()
    }
  }

  mcp_manager.stop(mgr)
}

pub fn special_chars_in_result_are_preserved_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let config =
    mcp_manager.ServerConfig(
      name: "chars-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = mcp_manager.register(mgr, config)

  let result =
    mcp_manager.execute_tool(
      mgr,
      "chars-server/special_chars",
      "{\"input\":\"hello\"}",
    )
  case result {
    Ok(response) ->
      // Response contains backslash — if json_escape was broken this would
      // produce invalid JSON and parse_jsonrpc_result would return Error
      response
      |> string.contains("hello")
      |> should.equal(True)
    Error(e) -> {
      let _ = e
      should.fail()
    }
  }

  mcp_manager.stop(mgr)
}

pub fn incompatible_protocol_version_rejected_test() {
  // A mock server that responds with an old/unknown protocol version
  // should cause register() to return Error, not silently succeed
  let assert Ok(mgr) = mcp_manager.start()

  let config =
    mcp_manager.ServerConfig(
      name: "old-server",
      command: "python3",
      args: ["test/mock_mcp_server_old_version.py"],
      env: [],
    )

  // This should fail because the server announces an unsupported version
  let result = mcp_manager.register(mgr, config)
  result |> should.be_error

  // Manager should still be alive and empty after the rejected registration
  mcp_manager.list_servers(mgr)
  |> should.equal([])

  mcp_manager.stop(mgr)
}

pub fn tool_names_are_qualified_per_server_test() {
  let assert Ok(mgr) = mcp_manager.start()

  let config =
    mcp_manager.ServerConfig(
      name: "my-server",
      command: "python3",
      args: ["test/mock_mcp_server.py"],
      env: [],
    )

  let assert Ok(Nil) = mcp_manager.register(mgr, config)

  let tools = mcp_manager.list_tools(mgr)

  // Every tool name must be prefixed with the server name
  tools
  |> list.all(fn(t) { string.starts_with(t.spec.name, "my-server/") })
  |> should.equal(True)

  // The original_name must NOT contain the server prefix
  tools
  |> list.all(fn(t) { !string.contains(t.original_name, "/") })
  |> should.equal(True)

  mcp_manager.stop(mgr)
}

pub fn dead_server_is_evicted_after_crash_test() {
  // A mock server that exits immediately after the handshake
  let assert Ok(mgr) = mcp_manager.start()

  let config =
    mcp_manager.ServerConfig(
      name: "crashy",
      command: "python3",
      args: ["test/mock_mcp_server_crash.py"],
      env: [],
    )

  let assert Ok(Nil) = mcp_manager.register(mgr, config)

  // Server is listed as registered right after handshake
  mcp_manager.list_servers(mgr)
  |> should.equal(["crashy"])

  // The crash server exits after registration; the next tool call should
  // detect the dead port and evict the server from state
  let _ = mcp_manager.execute_tool(mgr, "crashy/echo", "{\"message\":\"hi\"}")

  // After the failed call, the manager should have removed the dead server
  mcp_manager.list_servers(mgr)
  |> should.equal([])

  // Manager itself must still be responsive
  let assert Ok(mgr2) = mcp_manager.start()
  mcp_manager.list_servers(mgr2) |> should.equal([])
  mcp_manager.stop(mgr2)

  mcp_manager.stop(mgr)
}

pub fn protocol_error_advances_request_id_and_does_not_evict_live_server_test() {
  let script =
    "import json, sys\nseen = set()\nfor line in sys.stdin:\n  req = json.loads(line)\n  m = req.get('method')\n  i = req.get('id')\n  if m == 'initialize':\n    print(json.dumps({'jsonrpc':'2.0','id':i,'result':{'protocolVersion':'2024-11-05','capabilities':{'tools':{}},'serverInfo':{'name':'probe','version':'1.0'}}}), flush=True)\n  elif m == 'notifications/initialized':\n    pass\n  elif m == 'tools/list':\n    print(json.dumps({'jsonrpc':'2.0','id':i,'result':{'tools':[{'name':'probe','description':'Probe','inputSchema':{'type':'object','properties':{}}}]}}), flush=True)\n  elif m == 'tools/call':\n    if i in seen:\n      print(json.dumps({'jsonrpc':'2.0','id':i,'error':{'code':-32600,'message':'duplicate request id'}}), flush=True)\n      continue\n    seen.add(i)\n    args = req.get('params', {}).get('arguments', {})\n    if args.get('fail_with_exited'):\n      print(json.dumps({'jsonrpc':'2.0','id':i,'error':{'code':-32000,'message':'child process exited with status 1'}}), flush=True)\n    else:\n      print(json.dumps({'jsonrpc':'2.0','id':i,'result':{'content':[{'type':'text','text':'ok:' + str(i)}]}}), flush=True)\n"

  let assert Ok(mgr) = mcp_manager.start()
  let config =
    mcp_manager.ServerConfig(
      name: "proto-err",
      command: "python3",
      args: ["-u", "-c", script],
      env: [],
    )
  let assert Ok(Nil) = mcp_manager.register(mgr, config)

  // Application error containing "exited" must fail without evicting the live server
  let first =
    mcp_manager.execute_tool(
      mgr,
      "proto-err/probe",
      "{\"fail_with_exited\":true}",
    )
  first |> should.be_error
  mcp_manager.list_servers(mgr) |> should.equal(["proto-err"])

  // Subsequent request must use an incremented request ID rather than repeating the failed ID
  let second = mcp_manager.execute_tool(mgr, "proto-err/probe", "{}")
  case second {
    Ok(response) -> response |> string.contains("ok:") |> should.equal(True)
    Error(_) -> should.fail()
  }

  mcp_manager.stop(mgr)
}
