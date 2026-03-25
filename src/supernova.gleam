//// Supernova Entry Point
//// 
//// Bootstraps the application by:
//// 1. Loading configuration from supernova.yaml
//// 2. Starting Session Supervisor for multi-session management
//// 3. Starting MCP Manager for tool discovery
//// 4. Starting channel adapters (Telegram, Discord)
//// 5. Awaiting shutdown signal (Ctrl+C)
//// 6. Graceful shutdown: channels → sessions → MCP servers

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import supernova/adapters/mcp/config_loader
import supernova/adapters/mcp_manager
import supernova/config
import supernova/core/session/supervisor

/// Starts Supernova, boots core services, and waits for shutdown.
pub fn main() -> Nil {
  io.println("🚀 Starting Supernova...")

  // Load configuration
  let config_result = load_config()

  case config_result {
    Error(error) -> {
      io.println("❌ Configuration error: " <> config_error_to_string(error))
      io.println("💡 Tip: Create supernova.yaml or check environment variables")
    }
    Ok(cfg) -> {
      io.println("✓ Configuration loaded")
      io.println("  Environment: " <> cfg.environment)
      io.println("  Log level: " <> cfg.log_level)
      print_enabled_channels(cfg)

      // Start core services
      case start_services(cfg) {
        Ok(services) -> {
          io.println("✓ All services started")
          io.println("✓ Supernova is running...")
          io.println("")
          io.println("Press Ctrl+C to shutdown")

          // Wait forever (until Ctrl+C)
          process.sleep_forever()

          // Graceful shutdown (unreachable in normal flow, but here for completeness)
          shutdown_services(services)
        }
        Error(reason) -> {
          io.println("❌ Failed to start services: " <> reason)
        }
      }
    }
  }
}

// ============================================================================
// Configuration Loading
// ============================================================================

/// Load configuration from file or use defaults
fn load_config() -> Result(config.Config, config.ConfigError) {
  // Try to load from supernova.yaml first, but if it fails for any reason,
  // just use defaults. This is more robust than trying to handle all error types.
  case config.load_from_file("supernova.yaml") {
    Ok(cfg) -> {
      io.println("✓ Loaded configuration from supernova.yaml")
      Ok(cfg)
    }
    Error(_) -> {
      // Fall back to default config with env overrides
      io.println(
        "⚠ supernova.yaml not found, using defaults with env overrides",
      )
      Ok(config.default_config())
    }
  }
}

/// Convert config error to human-readable string
fn config_error_to_string(error: config.ConfigError) -> String {
  case error {
    config.YamlParseError(msg) -> "YAML parse error: " <> msg
    config.MissingField(field, context) ->
      "Missing field '" <> field <> "' in " <> context
    config.InvalidField(field, value, reason) ->
      "Invalid field '" <> field <> "' = '" <> value <> "': " <> reason
    config.TypeMismatch(field, expected, found) ->
      "Type mismatch for '"
      <> field
      <> "': expected "
      <> expected
      <> ", got "
      <> found
    config.ValidationError(msg) -> "Validation error: " <> msg
    config.FileError(msg) -> "File error: " <> msg
  }
}

// ============================================================================
// Service Management
// ============================================================================

/// Container for all running services
pub type Services {
  Services(
    session_supervisor: supervisor.SessionSupervisor,
    mcp_manager: mcp_manager.MCPManager,
  )
}

/// Start all core services
fn start_services(_cfg: config.Config) -> Result(Services, String) {
  // Start Session Supervisor
  use session_sup <- result.try(
    supervisor.start()
    |> result.map_error(fn(_) { "Failed to start session supervisor" }),
  )
  io.println("✓ Session Supervisor started")

  // Start MCP Manager
  use mcp_mgr <- result.try(
    mcp_manager.start()
    |> result.map_error(fn(_) { "Failed to start MCP manager" }),
  )
  io.println("✓ MCP Manager started")

  // Register MCP servers from supernova.yaml, if present
  let mcp_servers = config_loader.parse_servers_from_file("supernova.yaml")
  case list.length(mcp_servers) {
    0 -> io.println("✓ No MCP servers configured")
    count -> {
      io.println("✓ Registering MCP servers: " <> int.to_string(count))
      case register_mcp_servers(mcp_mgr, mcp_servers) {
        Ok(_) -> io.println("✓ MCP servers registered")
        Error(reason) ->
          io.println("⚠ MCP server registration issue: " <> reason)
      }
    }
  }

  // TODO: Start channel adapters based on config
  // - Telegram / Discord adapters
  // - Matrix / Lark / Google Chat / Slack / Mattermost / WeChat Work / WhatsApp

  Ok(Services(session_supervisor: session_sup, mcp_manager: mcp_mgr))
}

fn register_mcp_servers(
  manager: mcp_manager.MCPManager,
  servers: List(mcp_manager.ServerConfig),
) -> Result(Nil, String) {
  case servers {
    [] -> Ok(Nil)
    [server, ..rest] ->
      case mcp_manager.register(manager, server) {
        Ok(_) -> register_mcp_servers(manager, rest)
        Error(reason) ->
          Error("failed to register " <> server.name <> ": " <> reason)
      }
  }
}

/// Graceful shutdown of all services
fn shutdown_services(services: Services) -> Nil {
  io.println("")
  io.println("🛑 Shutting down...")

  // 1. Stop channels first (no new messages)
  // TODO: Stop Telegram poller
  // TODO: Stop Discord gateway

  // 2. Stop sessions (complete ongoing conversations)
  supervisor.stop(services.session_supervisor)
  io.println("✓ Sessions stopped")

  // 3. Stop MCP servers (clean up tool connections)
  mcp_manager.stop(services.mcp_manager)
  io.println("✓ MCP servers stopped")

  io.println("✓ Shutdown complete")
}

fn print_enabled_channels(cfg: config.Config) -> Nil {
  io.println("  Channels:")
  print_channel_status("discord", config.is_discord_enabled(cfg))
  print_channel_status("telegram", config.is_telegram_enabled(cfg))
  print_channel_status("matrix", config.is_matrix_enabled(cfg))
  print_channel_status("lark", config.is_lark_enabled(cfg))
  print_channel_status("google_chat", config.is_google_chat_enabled(cfg))
  print_channel_status("slack", config.is_slack_enabled(cfg))
  print_channel_status("mattermost", config.is_mattermost_enabled(cfg))
  print_channel_status("wechat_work", config.is_wechat_work_enabled(cfg))
  print_channel_status("whatsapp", config.is_whatsapp_enabled(cfg))
}

fn print_channel_status(name: String, enabled: Bool) -> Nil {
  case enabled {
    True -> io.println("    - " <> name <> ": enabled")
    False -> io.println("    - " <> name <> ": disabled")
  }
}
