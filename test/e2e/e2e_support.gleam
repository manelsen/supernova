//// E2E support — real channel registry + deterministic mocks.

import exception
import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import supernova/adapters/discord_gateway
import supernova/adapters/discord_router
import supernova/adapters/telegram
import supernova/adapters/telegram_router
import supernova/channel/channel_kit
import supernova/channel/port
import supernova/channel/registry
import supernova/config
import supernova/core/access/actor as access_actor
import supernova/core/access/types as access_types
import supernova/core/alerts/group_actor as alerts_actor
import supernova/core/audit_log/actor as audit_actor
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/closed_group/global as closed_group_global
import supernova/core/closed_group/pure as cg_pure
import supernova/core/instance_budget/actor as instance_budget
import supernova/core/rate_limit/actor as rate_limiter
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/core/syscall/actor as syscall_actor
import supernova/llm/pricing
import supernova/llm/provider
import supernova/self/core as self_core
import supernova/self/sampler
import test_workspace

pub const now = 1_700_000_000_000

pub fn mock_config() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}

/// Seed a born core so closed-group birth does not intercept a test turn.
pub fn seed_core(root: String, principal: String, prose: String) -> Nil {
  let sampled = sampler.Sampled(traits: ["temp_0"], seed: 1, attempts: 0)
  let assert Ok(_) =
    self_core.save_birth(root, principal, sampled, 1, prose, now)
  let assert Some(core) = self_core.load(root, principal)
  let assert Ok(_) = self_core.set_name(root, principal, core, "Lua", now)
  Nil
}

pub fn channel_config() -> config.Config {
  let base = config.default_config()
  config.Config(
    ..base,
    telegram: config.TelegramConfig(
      token: Some("telegram-token"),
      enabled: True,
      base_url: None,
    ),
    discord: config.DiscordConfig(
      token: Some("discord-token"),
      app_id: None,
      guild_id: None,
      enabled: True,
    ),
  )
}

pub fn with_runtime(cfg: config.Config, body: fn() -> a) -> a {
  with_runtime_root(cfg, fn(_root) { body() })
}

pub fn with_runtime_root(cfg: config.Config, body: fn(String) -> a) -> a {
  test_workspace.with_isolated_workspace("e2e-group", fn(root) {
    use <- exception.defer(closed_group_global.clear_runtime)
    let cfg = config.Config(..cfg, data_dir: root)
    closed_group_global.set_config(cfg)
    closed_group_global.set_clock(fn() { now })
    closed_group_global.set_alert_sender(fn(_, _) { Nil })

    let assert Ok(access) =
      access_actor.start_with_clock(
        cg_pure.access_config(cfg.access),
        root,
        fn() { now },
      )
    closed_group_global.set_access(access)

    let assert Ok(budget) =
      budget_actor.start_with_config(
        cg_pure.budget_config(cfg.role_budgets.member),
        20,
      )
    closed_group_global.set_budget(budget)

    let assert Ok(ledger) =
      ledger_actor.start_persistent_with_clock_and_day_key(
        root <> "/ledger",
        fn() { closed_group_global.now() },
        fn(timestamp) {
          pricing.day_key(timestamp, cfg.instance_budget.timezone)
        },
      )
    closed_group_global.set_ledger(ledger)

    let assert Ok(rate) =
      rate_limiter.start_with_clock(fn() { closed_group_global.now() })
    closed_group_global.set_rate(rate)

    let assert Ok(audit) = audit_actor.start(root <> "/audit")
    closed_group_global.set_audit(audit)

    let assert Ok(instance) =
      instance_budget.start_with_clock(cfg.instance_budget.timezone, fn() {
        closed_group_global.now()
      })
    closed_group_global.set_instance_budget(instance)

    let assert Ok(alerts) = alerts_actor.start()
    closed_group_global.set_alerts(alerts)

    let manifests =
      dict.from_list([
        #(
          cg_pure.role_key(access_types.Member),
          cg_pure.manifest_for(cfg.capabilities, access_types.Member),
        ),
        #(
          cg_pure.role_key(access_types.Admin),
          cg_pure.manifest_for(cfg.capabilities, access_types.Admin),
        ),
      ])
    let assert Ok(gateway) =
      syscall_actor.start_with_capabilities(
        None,
        Some(budget),
        Some(audit),
        manifests,
        fn(_, _) { Ok("tool-ok") },
      )
    closed_group_global.set_gateway(gateway)

    body(root)
  })
}

pub fn telegram_handler(
  llm_config: provider.ProviderConfig,
) -> port.ChannelHandler {
  let assert Ok(router) = telegram_router.start(llm_config)
  fn(inbound, events) {
    telegram_router.route_inbound_for_handler(router, inbound, events)
  }
}

pub fn discord_handler(
  llm_config: provider.ProviderConfig,
) -> port.ChannelHandler {
  let assert Ok(router) = discord_router.start(llm_config)
  fn(inbound, events) {
    discord_router.route_inbound_for_handler(router, inbound, events)
  }
}

pub fn telegram_update(
  chat_id: String,
  user_id: String,
  text: String,
) -> telegram.Update {
  let json =
    "{\"update_id\":1,\"message\":{\"message_id\":1,\"from\":{\"id\":"
    <> user_id
    <> ",\"is_bot\":false,\"first_name\":\"Tester\"},\"chat\":{\"id\":"
    <> chat_id
    <> ",\"type\":\"private\"},\"date\":1700000000,\"text\":\""
    <> text
    <> "\"}}"
  let assert Ok(update) = telegram.parse_update(json)
  update
}

pub fn telegram_start_registry(
  cfg: config.Config,
  handler: port.ChannelHandler,
  updates: List(telegram.Update),
  recorder: process.Subject(channel_kit.OutboundRecord),
) -> registry.ChannelRegistry {
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      cfg,
      handler,
      channel_kit.StartHooks(
        discord_events: [],
        telegram_updates: updates,
        slack_inbound_events: [],
        matrix_inbound_events: [],
        disable_telegram_polling: True,
        typing_keepalive_ms: 4000,
        stream_timeout_ms: 60_000,
        turn_hard_timeout_ms: 300_000,
        registry_id: "",
        outbound_records: Some(recorder),
        leave_group: None,
        leave_retry_ms: [5000, 30_000, 120_000],
        leave_recheck_ms: 30_000,
      ),
    )
  channel_registry
}

pub fn telegram_chat_member_update(
  chat_id: String,
  status: String,
) -> telegram.Update {
  let json =
    "{\"update_id\":1,\"my_chat_member\":{\"chat\":{\"id\":"
    <> chat_id
    <> ",\"type\":\"supergroup\",\"title\":\"Grupo\"},\"new_chat_member\":{\"status\":\""
    <> status
    <> "\"}}}"
  let assert Ok(update) = telegram.parse_update(json)
  update
}

pub fn telegram_start_registry_with_leave(
  cfg: config.Config,
  handler: port.ChannelHandler,
  updates: List(telegram.Update),
  recorder: process.Subject(channel_kit.OutboundRecord),
  leave_recorder: process.Subject(String),
) -> registry.ChannelRegistry {
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      cfg,
      handler,
      channel_kit.StartHooks(
        discord_events: [],
        telegram_updates: updates,
        slack_inbound_events: [],
        matrix_inbound_events: [],
        disable_telegram_polling: True,
        typing_keepalive_ms: 4000,
        stream_timeout_ms: 60_000,
        turn_hard_timeout_ms: 300_000,
        registry_id: "",
        outbound_records: Some(recorder),
        leave_group: Some(fn(chat_id) {
          process.send(leave_recorder, chat_id)
          True
        }),
        leave_retry_ms: [5000, 30_000, 120_000],
        leave_recheck_ms: 30_000,
      ),
    )
  channel_registry
}

pub fn discord_message_event(
  content: String,
  user_id: String,
) -> discord_gateway.DiscordEvent {
  let data =
    "{\"id\":\"m1\",\"channel_id\":\"dm1\",\"content\":\""
    <> content
    <> "\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"author\":{\"id\":\""
    <> user_id
    <> "\",\"username\":\"tester\",\"discriminator\":\"0\",\"bot\":false}}"
  discord_gateway.MessageCreate(data)
}

pub fn discord_guild_message_event(
  content: String,
  user_id: String,
  guild_id: String,
) -> discord_gateway.DiscordEvent {
  let data =
    "{\"id\":\"m1\",\"channel_id\":\"chan1\",\"guild_id\":\""
    <> guild_id
    <> "\",\"content\":\""
    <> content
    <> "\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"author\":{\"id\":\""
    <> user_id
    <> "\",\"username\":\"tester\",\"discriminator\":\"0\",\"bot\":false}}"
  discord_gateway.MessageCreate(data)
}

pub fn discord_start_registry(
  cfg: config.Config,
  handler: port.ChannelHandler,
  events: List(discord_gateway.DiscordEvent),
  recorder: process.Subject(channel_kit.OutboundRecord),
) -> registry.ChannelRegistry {
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      cfg,
      handler,
      channel_kit.StartHooks(
        discord_events: events,
        telegram_updates: [],
        slack_inbound_events: [],
        matrix_inbound_events: [],
        disable_telegram_polling: True,
        typing_keepalive_ms: 4000,
        stream_timeout_ms: 60_000,
        turn_hard_timeout_ms: 300_000,
        registry_id: "",
        outbound_records: Some(recorder),
        leave_group: None,
        leave_retry_ms: [5000, 30_000, 120_000],
        leave_recheck_ms: 30_000,
      ),
    )
  channel_registry
}

pub fn access_config(
  admins: List(String),
  members: List(String),
) -> config.AccessConfig {
  config.AccessConfig(
    mode: config.Allowlist,
    admins: admins,
    members: members,
    denied_reply: "Esta instância é privada.",
    allowed_chats: [],
  )
}

/// Wait until some outbound record contains `needle`.
///
/// Turns are asynchronous: a reply arrives as typing → placeholder → final
/// edit, so the content is not necessarily in the first record.
@external(erlang, "erlang", "monotonic_time")
fn monotonic_native() -> Int

@external(erlang, "erlang", "convert_time_unit")
fn convert_time_unit(value: Int, from: Atom, to: Atom) -> Int

type Atom

@external(erlang, "erlang", "binary_to_atom")
fn atom(name: String) -> Atom

fn monotonic_ms() -> Int {
  convert_time_unit(monotonic_native(), atom("native"), atom("millisecond"))
}

pub fn await_content(
  recorder: process.Subject(channel_kit.OutboundRecord),
  needle: String,
) -> Bool {
  await_content_loop(recorder, needle, monotonic_ms() + 5000)
}

fn await_content_loop(
  recorder: process.Subject(channel_kit.OutboundRecord),
  needle: String,
  deadline: Int,
) -> Bool {
  let remaining = deadline - monotonic_ms()
  case remaining <= 0 {
    True -> False
    False -> {
      let wait_ms = case remaining < 500 {
        True -> remaining
        False -> 500
      }
      case process.receive(recorder, within: wait_ms) {
        Ok(record) ->
          case string.contains(record.content, needle) {
            True -> True
            False -> await_content_loop(recorder, needle, deadline)
          }
        Error(_) -> await_content_loop(recorder, needle, deadline)
      }
    }
  }
}

pub fn telegram_start_registry_with_leave_result(
  cfg: config.Config,
  handler: port.ChannelHandler,
  updates: List(telegram.Update),
  recorder: process.Subject(channel_kit.OutboundRecord),
  leave_result: Bool,
  retry_ms: List(Int),
) -> registry.ChannelRegistry {
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      cfg,
      handler,
      channel_kit.StartHooks(
        discord_events: [],
        telegram_updates: updates,
        slack_inbound_events: [],
        matrix_inbound_events: [],
        disable_telegram_polling: True,
        typing_keepalive_ms: 4000,
        stream_timeout_ms: 60_000,
        turn_hard_timeout_ms: 300_000,
        registry_id: "",
        outbound_records: Some(recorder),
        leave_group: Some(fn(_chat_id) { leave_result }),
        leave_retry_ms: retry_ms,
        leave_recheck_ms: 30_000,
      ),
    )
  channel_registry
}
