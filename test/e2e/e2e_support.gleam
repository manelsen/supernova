//// E2E support — real channel registry + deterministic mocks.

import exception
import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import supernova/adapters/discord_gateway
import supernova/adapters/discord_router
import supernova/adapters/telegram
import supernova/adapters/telegram_router
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
import supernova/llm/provider
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

pub fn channel_config() -> config.Config {
  let base = config.default_config()
  config.Config(
    ..base,
    telegram: config.TelegramConfig(
      token: Some("telegram-token"),
      enabled: True,
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
  test_workspace.with_isolated_workspace("e2e-group", fn(root) {
    use <- exception.defer(closed_group_global.clear_runtime)
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
      ledger_actor.start_persistent_with_clock(root <> "/ledger", fn() { now })
    closed_group_global.set_ledger(ledger)

    let assert Ok(rate) = rate_limiter.start_with_clock(fn() { now })
    closed_group_global.set_rate(rate)

    let assert Ok(audit) = audit_actor.start(root <> "/audit")
    closed_group_global.set_audit(audit)

    let assert Ok(instance) =
      instance_budget.start_with_clock(cfg.instance_budget.timezone, fn() {
        now
      })
    closed_group_global.set_instance_budget(instance)

    let assert Ok(alerts) = alerts_actor.start()
    closed_group_global.set_alerts(alerts)

    let manifests =
      dict.from_list([
        #("member", cg_pure.manifest_for(cfg.capabilities, access_types.Member)),
        #("admin", cg_pure.manifest_for(cfg.capabilities, access_types.Admin)),
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

    body()
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
  recorder: process.Subject(registry.OutboundRecord),
) -> registry.ChannelRegistry {
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      cfg,
      handler,
      registry.StartHooks(
        discord_events: [],
        telegram_updates: updates,
        slack_inbound_events: [],
        matrix_inbound_events: [],
        disable_telegram_polling: True,
        typing_keepalive_ms: 4000,
        outbound_records: Some(recorder),
        leave_group: None,
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
  recorder: process.Subject(registry.OutboundRecord),
  leave_recorder: process.Subject(String),
) -> registry.ChannelRegistry {
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      cfg,
      handler,
      registry.StartHooks(
        discord_events: [],
        telegram_updates: updates,
        slack_inbound_events: [],
        matrix_inbound_events: [],
        disable_telegram_polling: True,
        typing_keepalive_ms: 4000,
        outbound_records: Some(recorder),
        leave_group: Some(fn(chat_id) { process.send(leave_recorder, chat_id) }),
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
  recorder: process.Subject(registry.OutboundRecord),
) -> registry.ChannelRegistry {
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      cfg,
      handler,
      registry.StartHooks(
        discord_events: events,
        telegram_updates: [],
        slack_inbound_events: [],
        matrix_inbound_events: [],
        disable_telegram_polling: True,
        typing_keepalive_ms: 4000,
        outbound_records: Some(recorder),
        leave_group: None,
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
