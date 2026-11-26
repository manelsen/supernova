//// PRD-S, S-02: the MCP client speaks the current protocol versions, gives
//// the model each tool's full schema, says why tools/list failed, and the
//// server it opens inherits Supernova's environment.

import envoy
import exception
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/mcp/protocol
import supernova/adapters/mcp_manager

fn server(name: String, env: List(#(String, String))) {
  mcp_manager.ServerConfig(
    name: name,
    command: "python3",
    args: ["test/mock_mcp_server.py"],
    env: env,
  )
}

/// Every version the SDK speaks is accepted; an unknown one is refused.
pub fn each_supported_version_registers_test() {
  list.each(protocol.supported_versions(), fn(version) {
    let assert Ok(mgr) = mcp_manager.start()
    mcp_manager.register(mgr, server("v", [#("MOCK_MCP_VERSION", version)]))
    |> should.equal(Ok(Nil))
    mcp_manager.stop(mgr)
  })
  let assert Ok(mgr) = mcp_manager.start()
  mcp_manager.register(mgr, server("v", [#("MOCK_MCP_VERSION", "2030-01-01")]))
  |> should.be_error
  mcp_manager.stop(mgr)
}

pub fn the_client_asks_for_the_latest_version_test() {
  protocol.request(1, "initialize", protocol.initialize_params())
  |> string.contains("\"protocolVersion\":\"2025-11-25\"")
  |> should.be_true
}

/// The model gets the server's schema, not an empty parameter list.
pub fn tools_carry_their_schema_test() {
  let assert Ok(mgr) = mcp_manager.start()
  let assert Ok(Nil) = mcp_manager.register(mgr, server("s", []))
  let assert Ok(echo_tool) =
    mcp_manager.list_tools(mgr)
    |> list.find(fn(tool) { tool.original_name == "echo" })
  let assert Some(schema) = echo_tool.spec.schema
  string.contains(schema, "\"message\"") |> should.be_true
  mcp_manager.stop(mgr)
}

/// A server whose tools/list cannot be read stays registered with none.
pub fn unreadable_tools_list_registers_with_none_test() {
  let assert Ok(mgr) = mcp_manager.start()
  mcp_manager.register(mgr, server("b", [#("MOCK_MCP_BROKEN_TOOLS", "1")]))
  |> should.equal(Ok(Nil))
  mcp_manager.list_tools(mgr) |> should.equal([])
  mcp_manager.stop(mgr)
}

/// The server inherits Supernova's environment, plus the configured `env`.
pub fn the_server_inherits_the_environment_test() {
  envoy.set("SUPERNOVA_MCP_INHERIT_PROBE", "herdado")
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_MCP_INHERIT_PROBE") })
  let assert Ok(mgr) = mcp_manager.start()
  let assert Ok(Nil) =
    mcp_manager.register(
      mgr,
      server("e", [#("MOCK_MCP_ECHO_ENV", "SUPERNOVA_MCP_INHERIT_PROBE")]),
    )
  let assert [probe] = mcp_manager.list_tools(mgr)
  probe.spec.description
  |> should.equal("SUPERNOVA_MCP_INHERIT_PROBE=herdado")
  mcp_manager.stop(mgr)
}

pub fn protocol_reading_test() {
  protocol.check_initialize("{\"protocolVersion\":\"2025-06-18\"}")
  |> should.equal(Ok("2025-06-18"))
  protocol.check_initialize("{}") |> should.be_error
  protocol.result_of("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"a\":1}}")
  |> should.equal(Ok("{\"a\":1}"))
  protocol.result_of(
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"no\"}}",
  )
  |> should.equal(Error("no (-32601)"))
  protocol.result_of("nada") |> should.be_error
  let assert Ok([tool]) =
    protocol.tools(
      "{\"tools\":[{\"name\":\"browser_click\",\"inputSchema\":{\"type\":\"object\"}}]}",
      fn(name) { name },
    )
  tool.name |> should.equal("browser_click")
  tool.description |> should.equal("")
  tool.schema |> should.equal(Some("{\"type\":\"object\"}"))
  let assert Ok([plain]) =
    protocol.tools("{\"tools\":[{\"name\":\"x\"}]}", fn(name) { "s__" <> name })
  plain.name |> should.equal("s__x")
  plain.schema |> should.equal(None)
  protocol.tools("{\"tools\":3}", fn(name) { name }) |> should.be_error
  protocol.call_text(
    "{\"content\":[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"image\",\"data\":\"x\"}]}",
  )
  |> should.equal(Ok("a\n[image omitido]"))
  protocol.call_text(
    "{\"content\":[{\"type\":\"text\",\"text\":\"ruim\"}],\"isError\":true}",
  )
  |> should.equal(Error("ruim"))
  protocol.call_text("[]") |> should.be_error
  protocol.notification("notifications/initialized")
  |> string.contains("\"method\":\"notifications/initialized\"")
  |> should.be_true
}
