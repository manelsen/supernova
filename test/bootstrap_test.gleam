import gleam/erlang/process
import gleeunit/should
import supernova/adapters/mcp_manager
import supernova/config
import supernova/core/session/supervisor

/// Test that the session supervisor starts successfully
pub fn session_supervisor_bootstrap_test() {
  let result = supervisor.start()
  should.be_ok(result)

  // Clean up
  case result {
    Ok(sup) -> supervisor.stop(sup)
    Error(_) -> Nil
  }
}

/// Test that the MCP manager starts successfully
pub fn mcp_manager_bootstrap_test() {
  let result = mcp_manager.start()
  should.be_ok(result)

  // Clean up
  case result {
    Ok(mgr) -> mcp_manager.stop(mgr)
    Error(_) -> Nil
  }
}

/// Test that config loading with defaults works
pub fn config_default_bootstrap_test() {
  let cfg = config.default_config()

  cfg.app_name
  |> should.equal("supernova")

  cfg.environment
  |> should.equal("development")

  cfg.log_level
  |> should.equal("info")
}

/// Test full bootstrap sequence (mimics main() function flow)
pub fn full_bootstrap_sequence_test() {
  // 1. Start session supervisor
  let assert Ok(session_sup) = supervisor.start()

  // 2. Start MCP manager
  let assert Ok(mcp_mgr) = mcp_manager.start()

  // 3. Verify both are running by doing simple operations
  let sessions = supervisor.list_sessions(session_sup)
  sessions
  |> should.equal([])

  let servers = mcp_manager.list_servers(mcp_mgr)
  servers
  |> should.equal([])

  // 4. Graceful shutdown in reverse order
  mcp_manager.stop(mcp_mgr)
  supervisor.stop(session_sup)

  // Small delay to allow actors to stop
  process.sleep(100)
}

/// Test that starting a session works after bootstrap
pub fn session_creation_after_bootstrap_test() {
  let assert Ok(session_sup) = supervisor.start()

  // Create a test session
  let result = supervisor.start_session(session_sup, "test-session-001")
  should.be_ok(result)

  // Verify it appears in the list
  let sessions = supervisor.list_sessions(session_sup)
  sessions
  |> should.equal(["test-session-001"])

  // Clean up
  let assert Ok(_) = supervisor.stop_session(session_sup, "test-session-001")
  supervisor.stop(session_sup)
}

/// Test that MCP server registration works after bootstrap
pub fn mcp_registration_after_bootstrap_test() {
  let assert Ok(mcp_mgr) = mcp_manager.start()

  // Note: We don't actually register a server here because we'd need
  // a real MCP server process. This test just verifies the manager
  // is ready to accept registrations.
  let servers = mcp_manager.list_servers(mcp_mgr)
  servers
  |> should.equal([])

  // Clean up
  mcp_manager.stop(mcp_mgr)
}
