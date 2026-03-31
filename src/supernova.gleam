//// Supernova Entry Point
//// 
//// Bootstraps the application by:
//// 1. Loading configuration from supernova.yaml
//// 2. Starting Session Supervisor for multi-session management
//// 3. Starting MCP Manager for tool discovery
//// 4. Starting channel adapters (Telegram, Discord)
//// 5. Awaiting shutdown signal (Ctrl+C)
//// 6. Graceful shutdown: channels → sessions → MCP servers

import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import supernova/adapters/discord_router
import supernova/adapters/mcp/config_loader
import supernova/adapters/mcp_manager
import supernova/adapters/telegram_router
import supernova/channel/port
import supernova/channel/registry
import supernova/config
import supernova/core/session/supervisor
import supernova/health/server as health_server
import supernova/llm/circuit_breaker/actor as cb_actor
import supernova/llm/circuit_breaker/global as cb_global
import supernova/llm/failover_cooldown/actor as cd_actor
import supernova/llm/failover_cooldown/global as cd_global
import supernova/llm/failover_cooldown/types as cd_types
import supernova/llm/provider
import supernova/metrics/actor as metrics_actor
import supernova/metrics/global as metrics_global
import supernova/tracing/actor as tracing_actor
import supernova/tracing/global as tracing_global
import supernova/tracing/types as tracing_types

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
          case string.contains(reason, "no LLM providers") {
            True -> {
              io.println("")
              io.println("Add this to your supernova.yaml providers section:")
              io.println("")
              io.println("  providers:")
              io.println("    openai:")
              io.println("      api_key: \"${SUPERNOVA_OPENAI_API_KEY}\"")
              io.println("      model: \"gpt-4o-mini\"")
              io.println("")
              io.println(
                "Then set the env var: SUPERNOVA_OPENAI_API_KEY=sk-...",
              )
              io.println(
                "Or run the wizard for guided setup: gleam run -m supernova/wizard_main",
              )
            }
            False -> Nil
          }
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
    channel_registry: registry.ChannelRegistry,
    health_server: health_server.HealthServer,
    metrics: metrics_actor.Metrics,
  )
}

/// Start all core services
fn start_services(cfg: config.Config) -> Result(Services, String) {
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

  // Start Health Check HTTP Server
  let health_port = 8080
  let assert Ok(metrics) = metrics_actor.start()
  metrics_global.set_metrics(metrics)
  io.println("✓ Metrics actor started")

  let tracer_config =
    tracing_types.TracerConfig(
      service_name: "supernova",
      otlp_endpoint: "",
      sampling_rate: 1.0,
    )
  let assert Ok(tracer) = tracing_actor.start(tracer_config)
  tracing_global.set_tracer(tracer)
  io.println("✓ Tracing actor started")

  let cb_config =
    cb_actor.CircuitBreakerConfig(
      failure_threshold: 5,
      recovery_timeout_ms: 30_000,
      half_open_max_calls: 3,
    )
  let assert Ok(cb) = cb_actor.start(cb_config)
  cb_global.set_circuit_breaker(cb)
  io.println("✓ Circuit breaker actor started")

  let cd_config =
    cd_types.FailoverCooldownConfig(
      initial_cooldown_ms: 30_000,
      max_cooldown_ms: 300_000,
    )
  let assert Ok(cooldown) = cd_actor.start(cd_config)
  cd_global.set_cooldown(cooldown)
  io.println("✓ Failover cooldown actor started")

  let health_srv = health_server.start(health_port, metrics)
  io.println("✓ Health server started on port " <> int.to_string(health_port))
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

  use channel_handler <- result.try(build_channel_handler(cfg, session_sup))

  // Start channel adapters based on config
  io.println("")
  io.println("Starting channel adapters...")
  let channel_reg = case
    registry.start_channels_with_handler(cfg, channel_handler)
  {
    Ok(reg) -> reg
    Error(reason) -> {
      io.println("Warning: Failed to start some channels: " <> reason)
      registry.ChannelRegistry(channels: dict.new(), streams: dict.new())
    }
  }

  Ok(Services(
    session_supervisor: session_sup,
    mcp_manager: mcp_mgr,
    channel_registry: channel_reg,
    health_server: health_srv,
    metrics: metrics,
  ))
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

fn build_channel_handler(
  cfg: config.Config,
  session_supervisor: supervisor.SessionSupervisor,
) -> Result(port.ChannelHandler, String) {
  use llm_config <- result.try(default_channel_llm_config(cfg))

  use discord_channel_router <- result.try(
    discord_router.start_with_session_supervisor(session_supervisor, llm_config)
    |> result.map_error(fn(_) { "Failed to start Discord channel router" }),
  )

  use telegram_channel_router <- result.try(
    telegram_router.start_with_session_supervisor(
      session_supervisor,
      llm_config,
    )
    |> result.map_error(fn(_) { "Failed to start Telegram channel router" }),
  )

  Ok(fn(inbound, stream_events) {
    route_channel_inbound_for_handler(
      inbound,
      discord_channel_router,
      telegram_channel_router,
      stream_events,
    )
  })
}

fn route_channel_inbound_for_handler(
  inbound: port.ChannelInbound,
  discord_channel_router: discord_router.DiscordRouter,
  telegram_channel_router: telegram_router.TelegramRouter,
  stream_events: process.Subject(port.ChannelStreamEvent),
) -> Result(port.ChannelHandlerResult, port.ChannelError) {
  case inbound_channel_name(inbound) {
    "discord" ->
      discord_router.route_inbound_for_handler(
        discord_channel_router,
        inbound,
        stream_events,
      )
    "telegram" ->
      telegram_router.route_inbound_for_handler(
        telegram_channel_router,
        inbound,
        stream_events,
      )
    channel -> Error(port.Ignored("channel not configured: " <> channel))
  }
}

fn inbound_channel_name(inbound: port.ChannelInbound) -> String {
  case inbound {
    port.InboundMessage(message) -> message.channel
    port.InboundInteraction(interaction) -> interaction.channel
  }
}

fn default_channel_llm_config(
  cfg: config.Config,
) -> Result(provider.ProviderConfig, String) {
  let provider_names =
    cfg.providers
    |> dict.keys
    |> list.sort(string.compare)

  case provider_names {
    [name, ..] ->
      case config.get_provider(cfg, name) {
        Some(provider_config) -> Ok(provider_config_to_runtime(provider_config))
        None -> Error("no configuration found for provider: " <> name)
      }
    [] ->
      Error(
        "no LLM providers configured — add a provider to supernova.yaml or run the wizard (gleam run -m supernova/wizard_main)",
      )
  }
}

fn provider_config_to_runtime(
  provider_config: config.ProviderConfig,
) -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: config.provider_runtime_name(provider_config.provider),
    api_key: provider_config.api_key,
    base_url: provider_config.base_url,
    default_model: case provider_config.model {
      Some(model) -> model
      None -> config.provider_default_model(provider_config.provider)
    },
  )
}

/// Graceful shutdown of all services
fn shutdown_services(services: Services) -> Nil {
  io.println("")
  io.println("🛑 Shutting down...")

  // 1. Stop channels first (no new messages)
  registry.stop_channels(services.channel_registry)

  // 2. Stop sessions (complete ongoing conversations)
  supervisor.stop(services.session_supervisor)
  io.println("✓ Sessions stopped")

  // 3. Stop MCP servers (clean up tool connections)
  mcp_manager.stop(services.mcp_manager)
  io.println("✓ MCP servers stopped")

  // 4. Stop health server (no-op if not started)
  let _ = health_server.stop(services.health_server)

  // 5. Stop metrics actor
  metrics_actor.reset(services.metrics)

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
