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
import gleam/erlang/process.{type Subject, sleep}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor as otp_actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import supernova/adapters/discord_router
import supernova/adapters/matrix_router
import supernova/adapters/mcp/config_loader
import supernova/adapters/mcp_manager
import supernova/adapters/sim_router
import supernova/adapters/slack_router
import supernova/adapters/telegram_router
import supernova/channel/port
import supernova/channel/registry
import supernova/config
import supernova/config_check
import supernova/core/access/actor as access_actor
import supernova/core/access/types as access_types
import supernova/core/alerts/group_actor as alerts_actor
import supernova/core/audit_log/actor as audit_actor
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/closed_group/global as closed_group_global
import supernova/core/closed_group/pure as closed_group_pure
import supernova/core/instance_budget/actor as instance_budget
import supernova/core/principal
import supernova/core/prompt_log
import supernova/core/rate_limit/actor as rate_limiter
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/core/session/supervisor
import supernova/core/syscall/actor as syscall_actor
import supernova/core/tool_dispatch
import supernova/core/workspace_policy/actor as workspace_policy_actor
import supernova/health/server as health_server
import supernova/llm/circuit_breaker/actor as cb_actor
import supernova/llm/circuit_breaker/global as cb_global
import supernova/llm/failover_cooldown/actor as cd_actor
import supernova/llm/failover_cooldown/global as cd_global
import supernova/llm/failover_cooldown/types as cd_types
import supernova/llm/pricing
import supernova/llm/provider
import supernova/metrics/actor as metrics_actor
import supernova/metrics/global as metrics_global
import supernova/self/reflection
import supernova/tools/browser
import supernova/tracing/actor as tracing_actor
import supernova/tracing/global as tracing_global
import supernova/tracing/types as tracing_types

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn current_timestamp() -> Int

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

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

      let issues = config_check.check(cfg)
      case config_check.is_bootable(issues) {
        False -> {
          io.println("❌ Configuration rejected:")
          io.println(config_check.format_issues(issues))
        }
        True -> {
          io.println(config_check.format_issues(issues))
          // Start core services
          case boot(cfg, current_timestamp) {
            Ok(services) -> {
              io.println("✓ All services started")
              io.println("✓ Supernova is running...")
              io.println("")
              io.println("Press Ctrl+C to shutdown")

              // Block until SIGTERM / shutdown signal
              wait_for_shutdown()

              // Graceful shutdown
              shutdown(services)
            }
            Error(reason) -> {
              io.println("❌ Failed to start services: " <> reason)
              case string.contains(reason, "no LLM providers") {
                True -> {
                  io.println("")
                  io.println(
                    "Add this to your supernova.yaml providers section:",
                  )
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
  }
}

// ============================================================================
// Configuration Loading
// ============================================================================

/// Load configuration from file or use defaults
fn load_config() -> Result(config.Config, config.ConfigError) {
  // Try to load from supernova.yaml first, but if it fails for any reason,
  // just use defaults. This is more robust than trying to handle all error types.
  case config.load_from_file("/config/supernova.yaml") {
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
pub type Runtime {
  Runtime(
    session_supervisor: supervisor.SessionSupervisor,
    mcp_manager: mcp_manager.MCPManager,
    channel_registry: registry.ChannelRegistry,
    health_server: health_server.HealthServer,
    metrics: metrics_actor.Metrics,
  )
}

/// Boot every service that `main` starts, with an injectable clock.
///
/// The harness passes a controllable clock and sets `environment` to
/// `"harness"`: in that mode the hourly reflection sweeper is not started
/// (the harness sweeps explicitly) and the health server binds an ephemeral
/// port, so repeated boots do not collide.
pub fn boot(cfg: config.Config, clock: fn() -> Int) -> Result(Runtime, String) {
  start_services(cfg, clock)
}

/// Start all core services
fn start_services(
  cfg: config.Config,
  clock: fn() -> Int,
) -> Result(Runtime, String) {
  browser.set_evaluate_allowed(cfg.tools.browser.allow_evaluate)
  use _ <- result.try(prompt_log.validate(cfg))
  closed_group_global.set_clock(clock)

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

  // Start infrastructure actors under a supervision tree

  let tracer_config =
    tracing_types.TracerConfig(
      service_name: "supernova",
      otlp_endpoint: "",
      sampling_rate: 1.0,
    )
  let cb_config =
    cb_actor.CircuitBreakerConfig(
      failure_threshold: 5,
      recovery_timeout_ms: 30_000,
      half_open_max_calls: 3,
    )
  let cd_config =
    cd_types.FailoverCooldownConfig(
      initial_cooldown_ms: 30_000,
      max_cooldown_ms: 300_000,
    )

  use _infra_sup <- result.try(
    start_infrastructure_supervisor(tracer_config, cb_config, cd_config)
    |> result.map_error(fn(_) { "Failed to start infrastructure supervisor" }),
  )
  io.println(
    "✓ Infrastructure supervisor started (metrics, tracing, circuit breaker, cooldown)",
  )

  // Retrieve metrics from global (set by supervisor child start)
  // Retry for up to 2 seconds to allow actors to fully register
  use metrics <- result.try(wait_for_metrics(100))

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

  use _closed_group_sup <- result.try(
    start_closed_group_supervisor_with_clock(cfg, clock)
    |> result.map_error(fn(reason) {
      "Failed to start closed-group supervisor: " <> reason
    }),
  )
  io.println("✓ Closed-group policy actors started")

  // Start channel adapters based on config
  io.println("")
  io.println("Starting channel adapters...")
  let channel_reg = case
    registry.start_channels_with_handler(cfg, channel_handler)
  {
    Ok(reg) -> reg
    Error(reason) -> {
      io.println("Warning: Failed to start some channels: " <> reason)
      registry.ChannelRegistry(
        id: "registry:none",
        channels: dict.new(),
        streams: dict.new(),
      )
    }
  }

  closed_group_global.set_alert_sender(fn(principal_id, text) {
    case principal.parse(principal_id) {
      Ok(speaker) -> {
        let target = case speaker.channel {
          "discord" -> "open-dm:" <> speaker.user_id
          _ -> speaker.user_id
        }
        let reply =
          port.ChannelReply(
            channel_id: target,
            content: text,
            reply_to_id: None,
            thread_id: None,
            typing: False,
            edit_message_id: None,
            interactive: None,
            media: [],
          )
        let _ = registry.send(channel_reg, speaker.channel, reply)
        Nil
      }
      Error(_) -> Nil
    }
  })

  // Start the hourly reflection sweeper outside the router. A controllable
  // clock (harness mode) means the harness triggers sweeps explicitly.
  case cfg.environment == "harness" {
    True -> Nil
    False ->
      case default_channel_llm_config(cfg) {
        Ok(llm_config) -> reflection.start_sweeper(cfg.data_dir, llm_config)
        Error(_) -> Nil
      }
  }

  // Start health server with real channel state callback
  let get_ready_channels = fn() { dict.keys(channel_reg.channels) }
  let health_srv =
    health_server.start(health_port(cfg), metrics, get_ready_channels)
  io.println(
    "✓ Health server started on port " <> int.to_string(health_port(cfg)),
  )

  Ok(Runtime(
    session_supervisor: session_sup,
    mcp_manager: mcp_mgr,
    channel_registry: channel_reg,
    health_server: health_srv,
    metrics: metrics,
  ))
}

fn health_port(cfg: config.Config) -> Int {
  case cfg.environment {
    "harness" -> 0
    "test" -> 0
    _ -> 8080
  }
}

// Wait for metrics actor to register in global with retry (up to 2s)
fn wait_for_metrics(attempts: Int) -> Result(metrics_global.Metrics, String) {
  case attempts <= 0 {
    True -> Error("Metrics actor not available after supervisor start")
    False -> {
      case metrics_global.get_metrics() {
        Some(m) -> Ok(m)
        None -> {
          sleep(100)
          wait_for_metrics(attempts - 1)
        }
      }
    }
  }
}

/// Start infrastructure actors under an OTP supervisor (one_for_one).
/// Each child re-registers its global reference on (re)start.
pub fn start_infrastructure_supervisor(
  tracer_config: tracing_types.TracerConfig,
  cb_config: cb_actor.CircuitBreakerConfig,
  cd_config: cd_types.FailoverCooldownConfig,
) -> Result(static_supervisor.Supervisor, String) {
  let builder =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.restart_tolerance(intensity: 5, period: 60)
    |> static_supervisor.add(
      supervision.worker(fn() {
        case metrics_actor.start_linked() {
          Ok(started) -> {
            metrics_global.set_metrics(started.data)
            Ok(started)
          }
          Error(e) -> Error(e)
        }
      }),
    )
    |> static_supervisor.add(
      supervision.worker(fn() {
        case tracing_actor.start_linked(tracer_config) {
          Ok(started) -> {
            tracing_global.set_tracer(started.data)
            Ok(started)
          }
          Error(e) -> Error(e)
        }
      }),
    )
    |> static_supervisor.add(
      supervision.worker(fn() {
        case cb_actor.start_linked(cb_config) {
          Ok(started) -> {
            cb_global.set_circuit_breaker(started.data)
            Ok(started)
          }
          Error(e) -> Error(e)
        }
      }),
    )
    |> static_supervisor.add(
      supervision.worker(fn() {
        case cd_actor.start_linked(cd_config) {
          Ok(started) -> {
            cd_global.set_cooldown(started.data)
            Ok(started)
          }
          Error(e) -> Error(e)
        }
      }),
    )

  case static_supervisor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(string.inspect(e))
  }
}

/// Start access, budget, ledger, rate, audit, instance-cap, alerts and tool
fn wrap_started(
  handle: Subject(a),
) -> Result(otp_actor.Started(Subject(a)), otp_actor.StartError) {
  case process.subject_owner(handle) {
    Ok(pid) -> Ok(otp_actor.Started(pid: pid, data: handle))
    Error(_) -> Error(otp_actor.InitFailed("actor has no owner"))
  }
}

/// Start access, budget, ledger, rate, audit, instance-cap, alerts and tool
/// gateway under one_for_one supervision. Each worker republishes its handle
/// globally so a restart is picked up without restarting the whole app.
pub fn start_closed_group_supervisor(
  cfg: config.Config,
) -> Result(static_supervisor.Supervisor, String) {
  start_closed_group_supervisor_with_clock(cfg, current_timestamp)
}

/// Start the closed-group policy actors on one clock. Every actor that
/// reasons about time (access, ledger day, rate windows, instance cap) uses
/// the same clock, so an injected clock (tests, harness) never disagrees with
/// the real one about the current day.
pub fn start_closed_group_supervisor_with_clock(
  cfg: config.Config,
  clock: fn() -> Int,
) -> Result(static_supervisor.Supervisor, String) {
  closed_group_global.set_config(cfg)
  closed_group_global.set_clock(clock)

  use _ <- result.try(
    ensure_dir(cfg.data_dir <> "/workspace")
    |> result.map_error(fn(reason) {
      "workspace policy unavailable: " <> reason
    }),
  )

  let builder =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.restart_tolerance(intensity: 5, period: 60)
    |> static_supervisor.add(
      supervision.worker(fn() {
        case audit_actor.start(cfg.data_dir <> "/audit_log") {
          Ok(started) -> {
            closed_group_global.set_audit(started)
            wrap_started(started)
          }
          Error(e) -> Error(e)
        }
      }),
    )
    |> static_supervisor.add(
      supervision.worker(fn() {
        case
          access_actor.start_with_clock(
            closed_group_pure.access_config(cfg.access),
            cfg.data_dir,
            clock,
          )
        {
          Ok(started) -> {
            closed_group_global.set_access(started)
            wrap_started(started)
          }
          Error(e) -> Error(e)
        }
      }),
    )
    |> static_supervisor.add(
      supervision.worker(fn() {
        case
          budget_actor.start_with_config_and_clock(
            closed_group_pure.budget_config(cfg.role_budgets.member),
            20,
            clock,
          )
        {
          Ok(started) -> {
            closed_group_global.set_budget(started)
            wrap_started(started)
          }
          Error(e) -> Error(e)
        }
      }),
    )
    |> static_supervisor.add(
      supervision.worker(fn() {
        case
          ledger_actor.start_persistent_with_clock_and_day_key(
            cfg.data_dir <> "/ledger",
            clock,
            fn(timestamp) {
              pricing.day_key(timestamp, cfg.instance_budget.timezone)
            },
          )
        {
          Ok(started) -> {
            closed_group_global.set_ledger(started)
            wrap_started(started)
          }
          Error(e) -> Error(e)
        }
      }),
    )
    |> static_supervisor.add(
      supervision.worker(fn() {
        case rate_limiter.start_with_clock(clock) {
          Ok(started) -> {
            closed_group_global.set_rate(started)
            wrap_started(started)
          }
          Error(e) -> Error(e)
        }
      }),
    )
    |> static_supervisor.add(
      supervision.worker(fn() {
        case
          instance_budget.start_with_clock(cfg.instance_budget.timezone, clock)
        {
          Ok(started) -> {
            closed_group_global.set_instance_budget(started)
            wrap_started(started)
          }
          Error(e) -> Error(e)
        }
      }),
    )
    |> static_supervisor.add(
      supervision.worker(fn() {
        case alerts_actor.start() {
          Ok(started) -> {
            closed_group_global.set_alerts(started)
            wrap_started(started)
          }
          Error(e) -> Error(e)
        }
      }),
    )
    |> static_supervisor.add(
      supervision.worker(fn() {
        case closed_group_global.get_budget(), closed_group_global.get_audit() {
          Some(budget), Some(audit) -> {
            let manifests =
              dict.from_list([
                #(
                  closed_group_pure.role_key(access_types.Member),
                  closed_group_pure.manifest_for(
                    cfg.capabilities,
                    access_types.Member,
                  ),
                ),
                #(
                  closed_group_pure.role_key(access_types.Admin),
                  closed_group_pure.manifest_for(
                    cfg.capabilities,
                    access_types.Admin,
                  ),
                ),
              ])
            let workspace_root = config.workspace_root(cfg)
            let policy_result = case ensure_dir(workspace_root) {
              Error(reason) ->
                Error(otp_actor.InitFailed(
                  "workspace policy unavailable: " <> reason,
                ))
              Ok(_) ->
                case workspace_policy_actor.start(workspace_root) {
                  Ok(policy) -> Ok(policy)
                  Error(_) ->
                    Error(otp_actor.InitFailed(
                      "workspace policy failed to start",
                    ))
                }
            }
            case policy_result {
              Error(error) -> Error(error)
              Ok(policy) ->
                case
                  syscall_actor.start_with_capabilities(
                    Some(policy),
                    Some(budget),
                    Some(audit),
                    manifests,
                    tool_dispatch.execute,
                  )
                {
                  Ok(started) -> {
                    closed_group_global.set_gateway(started)
                    wrap_started(started)
                  }
                  Error(e) -> Error(e)
                }
            }
          }
          _, _ ->
            Error(otp_actor.InitFailed("closed-group handles unavailable"))
        }
      }),
    )

  case static_supervisor.start(builder) {
    Ok(started) -> {
      closed_group_global.set_enforced(True)
      Ok(started.data)
    }
    Error(e) -> Error(string.inspect(e))
  }
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

pub fn build_channel_handler(
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

  use slack_channel_router <- result.try(
    slack_router.start_with_session_supervisor(session_supervisor, llm_config)
    |> result.map_error(fn(_) { "Failed to start Slack channel router" }),
  )

  use matrix_channel_router <- result.try(
    matrix_router.start_with_session_supervisor(session_supervisor, llm_config)
    |> result.map_error(fn(_) { "Failed to start Matrix channel router" }),
  )

  use sim_channel_router <- result.try(
    sim_router.start_with_session_supervisor(session_supervisor, llm_config)
    |> result.map_error(fn(_) { "Failed to start sim channel router" }),
  )

  Ok(fn(inbound, stream_events) {
    route_channel_inbound_for_handler(
      inbound,
      discord_channel_router,
      telegram_channel_router,
      slack_channel_router,
      matrix_channel_router,
      sim_channel_router,
      stream_events,
    )
  })
}

fn route_channel_inbound_for_handler(
  inbound: port.ChannelInbound,
  discord_channel_router: discord_router.DiscordRouter,
  telegram_channel_router: telegram_router.TelegramRouter,
  slack_channel_router: slack_router.SlackRouter,
  matrix_channel_router: matrix_router.MatrixRouter,
  sim_channel_router: sim_router.SimRouter,
  stream_events: process.Subject(port.ChannelStreamEvent),
) -> Result(port.ChannelHandlerResult, port.ChannelError) {
  let channel = inbound_channel_name(inbound)
  case channel {
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
    "slack" ->
      slack_router.route_inbound_for_handler(
        slack_channel_router,
        inbound,
        stream_events,
      )
    "matrix" ->
      matrix_router.route_inbound_for_handler(
        matrix_channel_router,
        inbound,
        stream_events,
      )
    "sim" ->
      sim_router.route_inbound_for_handler(
        sim_channel_router,
        inbound,
        stream_events,
      )
    _ -> {
      io.println("⚠ Received message for unconfigured channel: " <> channel)
      Error(port.Ignored("channel not configured: " <> channel))
    }
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

/// Block until SIGTERM or shutdown signal is received.
/// Uses Erlang's trap_exit to catch exit signals.
@external(erlang, "supernova_signal_ffi", "wait_for_shutdown")
pub fn wait_for_shutdown() -> Nil

/// Graceful shutdown of all services
pub fn shutdown(services: Runtime) -> Nil {
  io.println("")
  io.println("🛑 Shutting down...")

  // 1. Stop channels first (no new messages, releases the sim port)
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

  // 6. Unpublish the closed-group runtime so a later boot starts clean.
  closed_group_global.clear_runtime()

  io.println("✓ Shutdown complete")
}

fn print_enabled_channels(cfg: config.Config) -> Nil {
  io.println("  Channels:")
  print_channel_status("discord", config.is_discord_enabled(cfg))
  print_channel_status("telegram", config.is_telegram_enabled(cfg))
  print_channel_status("sim", config.is_sim_enabled(cfg))
  print_channel_status("matrix", config.is_matrix_enabled(cfg))
  print_channel_status("lark", config.is_lark_enabled(cfg))
  print_channel_status("google_chat", config.is_google_chat_enabled(cfg))
  print_channel_status("slack", config.is_slack_enabled(cfg))
  print_channel_status("mattermost", config.is_mattermost_enabled(cfg))
  print_channel_status("wechat_work", config.is_wechat_work_enabled(cfg))
  print_channel_status("whatsapp", config.is_whatsapp_enabled(cfg))
  config.channel_names()
  |> list.filter(fn(channel) {
    config.channel_support(channel) == config.Experimental
    && config.is_channel_enabled(cfg, channel)
  })
  |> list.each(fn(channel) {
    io.println(
      "warn: channel "
      <> channel
      <> " is experimental: not covered by end-to-end tests",
    )
  })
}

fn print_channel_status(name: String, enabled: Bool) -> Nil {
  case enabled {
    True -> io.println("    - " <> name <> ": enabled")
    False -> io.println("    - " <> name <> ": disabled")
  }
}
