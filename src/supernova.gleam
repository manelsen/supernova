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
import supernova/adapters/channel_router
import supernova/adapters/direct_routers
import supernova/adapters/mcp/config_loader
import supernova/adapters/mcp_manager
import supernova/agenda/runtime as agenda_runtime
import supernova/agenda/schedule as agenda_schedule
import supernova/agenda/sweeper as agenda_sweeper
import supernova/channel/catalog as channel_catalog
import supernova/channel/channel_kit
import supernova/channel/health as channel_health
import supernova/channel/inbound_media
import supernova/channel/inbox
import supernova/channel/media_boot
import supernova/channel/port
import supernova/channel/registry
import supernova/channel/webhook_server
import supernova/config
import supernova/config_check
import supernova/core/access/actor as access_actor
import supernova/core/access/types as access_types
import supernova/core/alerts/group_actor as alerts_actor
import supernova/core/audit_log/actor as audit_actor
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/closed_group/global as closed_group_global
import supernova/core/closed_group/pure as closed_group_pure
import supernova/core/closed_group/runtime as closed_group_runtime
import supernova/core/executor
import supernova/core/identity/aliases
import supernova/core/instance_budget/actor as instance_budget
import supernova/core/principal
import supernova/core/prompt_log
import supernova/core/rate_limit/actor as rate_limiter
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/core/session/history_store
import supernova/core/session/supervisor
import supernova/core/syscall/actor as syscall_actor
import supernova/core/tool_dispatch
import supernova/core/tool_limits
import supernova/core/workspace_policy/actor as workspace_policy_actor
import supernova/health/server as health_server
import supernova/llm/catalog
import supernova/llm/circuit_breaker/actor as cb_actor
import supernova/llm/circuit_breaker/global as cb_global
import supernova/llm/failover_cooldown/actor as cd_actor
import supernova/llm/failover_cooldown/global as cd_global
import supernova/llm/failover_cooldown/types as cd_types
import supernova/llm/pricing
import supernova/llm/provider
import supernova/memory/boot as memory_boot
import supernova/metrics/actor as metrics_actor
import supernova/metrics/global as metrics_global
import supernova/metrics/record
import supernova/self/desk
import supernova/self/reflection
import supernova/self/tasks
import supernova/sondas/sonda
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
    /// The agents' processes: each one the only writer of its agent's state.
    desks: desk.DeskSupervisor,
    mcp_manager: mcp_manager.MCPManager,
    channel_registry: registry.ChannelRegistry,
    health_server: health_server.HealthServer,
    metrics: metrics_actor.Metrics,
    /// Run the agenda entries due now and return how many ran. Started on a
    /// half-minute clock in production; the harness calls it explicitly.
    sweep_agenda: fn() -> Int,
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
  tool_limits.configure(tool_limits.from_seconds(cfg.tools.timeouts))
  use _ <- result.try(prompt_log.validate(cfg))
  use _ <- result.try(config.validate_recall(cfg))
  closed_group_global.set_clock(clock)

  // Start Session Supervisor
  use session_sup <- result.try(
    supervisor.start_with_history(history_store.HistoryStore(
      data_dir: cfg.data_dir,
      limit: cfg.conversation.history_limit,
    ))
    |> result.map_error(fn(_) { "Failed to start session supervisor" }),
  )
  io.println("✓ Session Supervisor started")

  use desks <- result.try(
    desk.start_supervisor()
    |> result.map_error(fn(_) { "Failed to start the agents' processes" }),
  )

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

  // The durable inbox opens before any channel delivers a message, and
  // what the last stop left waiting is taken now: a message that arrives
  // once channels start is never part of it.
  let left_waiting = start_inbox(cfg.data_dir)

  // Who reads the audio, video and documents people send (PRD-A).
  case media_boot.publish(cfg) {
    True ->
      io.println("✓ Media reader on: " <> cfg.media.reader_model <> " (Gemini)")
    False ->
      io.println("Media reader off: audio, video and documents become notes")
  }

  // Images of turns that never ran (PRD-C, C-05).
  let _ = inbound_media.sweep(cfg.data_dir, inbound_media.max_age_ms)

  // Linked identities (PRD-I) resolve before any message is gated.
  case aliases.load(cfg.data_dir) {
    Ok(Nil) -> Nil
    Error(reason) ->
      io.println(
        "Warning: "
        <> reason
        <> "; linked identities count as separate people until it is fixed",
      )
  }

  // What /model may offer: every configured provider with a key, each with
  // its own models. Published before any channel hands over a message.
  publish_model_catalog(cfg)

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
        health: channel_health.start(),
      )
    }
  }

  start_webhook_server(cfg)

  declare_boot_metrics(
    registry.list_channels(channel_reg),
    default_channel_llm_config(cfg)
      |> result.map(fn(default) { catalog.choices(catalog.current(default)) }),
  )
  replay_inbox(channel_reg, channel_handler, left_waiting)

  closed_group_global.set_alert_sender(fn(principal_id, text) {
    case principal.parse(principal_id) {
      Ok(speaker) -> {
        let target =
          channel_catalog.get(speaker.channel).private_chat_for(speaker.user_id)
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

  // The agenda: entries come due as messages in the person's private chat,
  // run through the same handler and per-chat lane as any message. It stays
  // off with a timezone it cannot resolve rather than run at the wrong hour.
  let deliver_agenda = fn(message) {
    case
      registry.inject(
        channel_reg,
        channel_handler,
        port.inbound_message(message),
      )
    {
      Ok(Nil) -> Nil
      Error(error) ->
        io.println_error(
          "error: agenda delivery failed: " <> string.inspect(error),
        )
    }
  }
  publish_memory(cfg)
  let sweep_agenda = case
    agenda_schedule.timezone_offset(cfg.instance_budget.timezone)
  {
    Error(Nil) -> {
      agenda_runtime.clear()
      io.println(
        "⚠ Agenda off: unsupported timezone "
        <> cfg.instance_budget.timezone
        <> " (use America/Sao_Paulo or UTC)",
      )
      fn() { 0 }
    }
    Ok(agenda_offset) -> {
      agenda_runtime.configure(agenda_runtime.Context(
        data_dir: cfg.data_dir,
        offset_minutes: agenda_offset,
        clock: clock,
      ))
      case cfg.environment == "harness" {
        True -> Nil
        False ->
          agenda_sweeper.start(
            cfg.data_dir,
            agenda_offset,
            clock,
            deliver_agenda,
          )
      }
      fn() {
        agenda_sweeper.sweep(
          cfg.data_dir,
          agenda_offset,
          clock(),
          deliver_agenda,
        )
      }
    }
  }

  // Tasks in the background (PRD-F, phase B): results come back as
  // messages through the same handler and lane as the agenda. At boot,
  // tasks a restart cut short are told as interrupted (D6), and results
  // not delivered yet are delivered.
  start_tasks(cfg, clock, fn(message) {
    registry.inject(channel_reg, channel_handler, port.inbound_message(message))
    |> result.map_error(string.inspect)
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
  let get_channels = fn() {
    channel_health.snapshot(channel_reg.health, channel_health.now_ms())
  }
  let health_srv = health_server.start(health_port(cfg), metrics, get_channels)
  io.println(
    "✓ Health server started on port " <> int.to_string(health_port(cfg)),
  )

  Ok(Runtime(
    session_supervisor: session_sup,
    desks: desks,
    mcp_manager: mcp_mgr,
    channel_registry: channel_reg,
    health_server: health_srv,
    metrics: metrics,
    sweep_agenda: sweep_agenda,
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
  case cfg.routing.parallel {
    True -> Ok(direct_channel_handler(session_supervisor, llm_config))
    False -> actor_channel_handler(session_supervisor, llm_config)
  }
}

/// `routing.parallel`: the pre-LLM phase runs in each chat's lane (PRD-P,
/// P-05). One state per channel, in ETS, shared by the lanes. The table comes
/// from the adapters layer; the core never names a channel (PRD-C, C-01).
fn direct_channel_handler(
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> port.ChannelHandler {
  let handlers = direct_routers.handlers(session_supervisor, llm_config)
  fn(inbound, stream_events) {
    let channel = inbound_channel_name(inbound)
    case dict.get(handlers, channel) {
      Ok(handler) -> handler(inbound, stream_events)
      Error(Nil) -> {
        io.println("⚠ Received message for unconfigured channel: " <> channel)
        Error(port.Ignored("channel not configured: " <> channel))
      }
    }
  }
}

/// The pre-LLM phase in each channel's router actor, one message at a time
/// per channel. The table comes from the channel catalog: every channel whose
/// traits say it routes inbound (PRD-C, C-01).
fn actor_channel_handler(
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> Result(port.ChannelHandler, String) {
  use routers <- result.try(
    channel_catalog.all()
    |> list.filter(fn(channel) { channel.routes_inbound })
    |> list.try_map(fn(channel) {
      channel_router.start_with_session_supervisor(
        channel.name,
        session_supervisor,
        llm_config,
      )
      |> result.map(fn(router) { #(channel.name, router) })
      |> result.map_error(fn(_) {
        "Failed to start " <> channel.name <> " channel router"
      })
    }),
  )
  let routers = dict.from_list(routers)
  Ok(fn(inbound, stream_events) {
    route_channel_inbound_for_handler(inbound, routers, stream_events)
  })
}

/// Route an inbound event to the router of its channel: the table holds
/// every channel whose traits say it routes inbound (PRD-C, C-01).
fn route_channel_inbound_for_handler(
  inbound: port.ChannelInbound,
  routers: dict.Dict(String, channel_router.ChannelRouter),
  stream_events: process.Subject(port.ChannelStreamEvent),
) -> Result(port.ChannelHandlerResult, port.ChannelError) {
  let channel = inbound_channel_name(inbound)
  case dict.get(routers, channel) {
    Ok(router) ->
      channel_router.route_inbound_for_handler(router, inbound, stream_events)
    Error(Nil) -> {
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

/// Open the inbox and take what the last stop left waiting.
fn start_inbox(data_dir: String) -> List(inbox.Pending) {
  case inbox.start(data_dir) {
    Ok(box) -> {
      inbox.set_global(box)
      io.println("✓ Durable inbox opened")
      inbox.recover(box, channel_kit.current_timestamp())
    }
    Error(_) -> {
      io.println(
        "Warning: durable inbox not opened; a restart loses queued messages",
      )
      []
    }
  }
}

/// Answer what was still waiting when Supernova last stopped (`pending`,
/// from `inbox.recover` before the channels started).
pub fn replay_inbox(
  channel_reg: registry.ChannelRegistry,
  handler: port.ChannelHandler,
  pending: List(inbox.Pending),
) -> Nil {
  case inbox.global() {
    None -> Nil
    Some(box) -> {
      list.each(pending, fn(entry) {
        let outcome = case
          registry.replay(channel_reg, handler, entry.message)
        {
          Ok(Nil) -> "replayed"
          Error(_) -> {
            inbox.done(box, entry.key, channel_kit.current_timestamp())
            "channel_missing"
          }
        }
        record.count("inbox_recovered_total", [#("outcome", outcome)])
      })
      case pending {
        [] -> Nil
        _ ->
          io.println(
            "✓ Answering "
            <> int.to_string(list.length(pending))
            <> " message(s) left waiting by the last stop",
          )
      }
    }
  }
}

/// Publish the series Supernova knows it will record at zero, so the
/// first event after a restart reaches the dashboard (see `record.declare`).
pub fn declare_boot_metrics(
  channels: List(String),
  llm: Result(List(catalog.Choice), String),
) -> Nil {
  list.each(channels, fn(channel) {
    channel_kit.declare_metrics(channel)
    closed_group_runtime.declare_gate_metrics(channel)
  })
  agenda_sweeper.declare_metrics()
  tasks.declare_metrics()
  sonda.declare_metrics()
  executor.declare_tool_metrics()
  list.each(["replayed", "channel_missing"], fn(outcome) {
    record.declare("inbox_recovered_total", [#("outcome", outcome)])
  })
  case llm {
    Ok(choices) ->
      list.each(choices, fn(choice) {
        executor.declare_metrics(choice.provider, choice.model)
        closed_group_runtime.declare_usage_metrics(
          choice.provider,
          choice.model,
        )
      })
    Error(_) -> Nil
  }
}

/// The gate and `lembrar` read their settings from here (PRD-M).
fn publish_memory(cfg: config.Config) -> Nil {
  case memory_boot.publish(cfg) {
    True -> io.println("✓ Memory on: gate and lembrar (Gemini Decision)")
    False -> Nil
  }
}

fn default_channel_llm_config(
  cfg: config.Config,
) -> Result(provider.ProviderConfig, String) {
  config.selected_provider(cfg)
  |> result.map(fn(selected) { catalog.runtime_config(selected.1) })
}

fn publish_model_catalog(cfg: config.Config) -> Nil {
  case default_channel_llm_config(cfg) {
    Ok(default) -> {
      let cat = catalog.from_config(cfg, default)
      catalog.set_global(cat)
      warn_unpriced_models(cfg, cat)
    }
    Error(_) -> catalog.clear_global()
  }
}

/// A model without its own price is charged at the default price, which
/// can understate what an expensive model costs against the ceilings.
fn warn_unpriced_models(cfg: config.Config, cat: catalog.Catalog) -> Nil {
  case dict.is_empty(cfg.pricing.models) {
    True -> Nil
    False ->
      catalog.choices(cat)
      |> list.filter(fn(choice) {
        !dict.has_key(cfg.pricing.models, choice.model)
      })
      |> list.each(fn(choice) {
        io.println(
          "Warning: model "
          <> choice.model
          <> " has no entry under pricing.models; its cost counts at the default price",
        )
      })
  }
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
  webhook_server.stop_global()
  registry.stop_channels(services.channel_registry)

  // 2. Stop sessions (complete ongoing conversations)
  supervisor.stop(services.session_supervisor)
  io.println("✓ Sessions stopped")

  // 2b. The turns are done: stop the agents' processes (each change they
  // took is already on disk).
  desk.stop_supervisor(services.desks)

  // 3. Stop MCP servers (clean up tool connections)
  mcp_manager.stop(services.mcp_manager)
  io.println("✓ MCP servers stopped")

  // 4. Stop health server (no-op if not started)
  let _ = health_server.stop(services.health_server)

  // 5. Stop metrics actor
  metrics_actor.reset(services.metrics)

  // 6. Unpublish the closed-group runtime so a later boot starts clean.
  closed_group_global.clear_runtime()

  // 7. The lanes have drained: write the inbox's last marks and stop it, so
  // the next boot (or an in-process one) is the file's only owner. The file
  // stays: it is what the next boot recovers.
  case inbox.global() {
    Some(box) -> inbox.stop(box)
    None -> Nil
  }
  inbox.clear_global()
  catalog.clear_global()

  io.println("✓ Shutdown complete")
}

/// The webhook server listens only when an enabled channel receives by
/// webhook (PRD-C, C-02).
fn start_webhook_server(cfg: config.Config) -> Nil {
  let needed =
    channel_catalog.all()
    |> list.any(fn(channel) {
      channel.receives_by_webhook
      && config.is_channel_enabled(cfg, channel.name)
    })
  case needed {
    False -> Nil
    True ->
      case webhook_server.start_global(cfg.webhook.bind, cfg.webhook.port) {
        Ok(Nil) ->
          io.println(
            "✓ Webhook server on "
            <> cfg.webhook.bind
            <> ":"
            <> int.to_string(cfg.webhook.port),
          )
        Error(reason) -> io.println("Warning: " <> reason)
      }
  }
}

fn print_enabled_channels(cfg: config.Config) -> Nil {
  io.println("  Channels:")
  channel_catalog.all()
  |> list.each(fn(channel) {
    print_channel_status(
      channel.name,
      config.is_channel_enabled(cfg, channel.name),
    )
  })
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

fn start_tasks(
  cfg: config.Config,
  clock: fn() -> Int,
  deliver: fn(port.ChannelMessage) -> Result(Nil, String),
) -> Nil {
  let context =
    tasks.Context(
      data_dir: cfg.data_dir,
      offset_minutes: result.unwrap(
        agenda_schedule.timezone_offset(cfg.instance_budget.timezone),
        0,
      ),
      clock: clock,
      limit_ms: tasks.default_limit_ms,
      deliver: deliver,
      can_deliver: fn(principal) {
        case closed_group_global.get_runtime() {
          Some(runtime) ->
            closed_group_runtime.precheck(runtime, principal, clock())
            |> result.is_ok
          None -> True
        }
      },
    )
  case tasks.start(context) {
    Ok(started) -> {
      let interrupted = tasks.recover(started)
      case interrupted > 0 {
        True ->
          io.println(
            "tasks: "
            <> int.to_string(interrupted)
            <> " interrupted by the restart",
          )
        False -> Nil
      }
    }
    Error(error) ->
      io.println_error("error: tasks did not start: " <> string.inspect(error))
  }
}
