import discord_fake
import e2e/e2e_support as support
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/channel/channel_kit
import supernova/channel/health as channel_health
import supernova/channel/registry
import supernova/config
import supernova/core/access/types as access_types
import supernova/core/closed_group/pure as cg_pure
import supernova/core/executor
import supernova/health/types as health_types
import supernova/llm/provider

fn cfg(members: List(String)) -> config.Config {
  let base = support.channel_config()
  config.Config(
    ..base,
    access: support.access_config([], members),
    capabilities: config.CapabilitiesConfig(
      member: config.RoleCapabilitiesConfig(allowed: [], denied: []),
      admin: config.RoleCapabilitiesConfig(allowed: ["*"], denied: []),
    ),
  )
}

fn collect_records(
  recorder: process.Subject(channel_kit.OutboundRecord),
  acc: List(channel_kit.OutboundRecord),
) -> List(channel_kit.OutboundRecord) {
  case process.receive(recorder, within: 500) {
    Ok(record) -> collect_records(recorder, [record, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

pub fn authorized_member_receives_reply_test() {
  support.with_runtime_root(cfg(["discord:456"]), fn(root) {
    support.seed_core(root, "discord:456", "Núcleo de teste.")
    let recorder = process.new_subject()
    let channel_registry =
      support.discord_start_registry(
        support.channel_config(),
        support.discord_handler(support.mock_config()),
        [support.discord_message_event("oi", "456")],
        recorder,
      )
    support.await_content(recorder, "Mock response")
    |> should.equal(True)
    registry.stop_channels(channel_registry)
  })
}

pub fn authorized_guild_receives_reply_test() {
  let base = cfg(["discord:456"])
  let cfg =
    config.Config(
      ..base,
      access: config.AccessConfig(..base.access, allowed_chats: [
        "discord:guild:guild1",
      ]),
    )
  support.with_runtime_root(cfg, fn(root) {
    support.seed_core(root, "discord:456", "Núcleo de teste.")
    let recorder = process.new_subject()
    let channel_registry =
      support.discord_start_registry(
        support.channel_config(),
        support.discord_handler(support.mock_config()),
        [support.discord_guild_message_event("oi", "456", "guild1")],
        recorder,
      )
    support.await_content(recorder, "Mock response")
    |> should.equal(True)
    registry.stop_channels(channel_registry)
  })
}

pub fn unauthorized_gets_denied_once_test() {
  support.with_runtime(cfg(["discord:456"]), fn() {
    let recorder = process.new_subject()
    let channel_registry =
      support.discord_start_registry(
        support.channel_config(),
        support.discord_handler(support.mock_config()),
        [
          support.discord_message_event("oi", "999"),
          support.discord_message_event("de novo", "999"),
        ],
        recorder,
      )
    let assert Ok(record) = process.receive(recorder, within: 5000)
    record.content |> should.equal("Esta instância é privada.")
    process.receive(recorder, within: 400) |> should.equal(Error(Nil))
    registry.stop_channels(channel_registry)
  })
}

pub fn exhausted_budget_reply_test() {
  let base = cfg(["discord:456"])
  let cfg =
    config.Config(
      ..base,
      role_budgets: config.RoleBudgetsConfig(
        member: config.RoleBudgetConfig(
          tokens_per_hour: 0,
          tool_calls_per_hour: 10,
        ),
        admin: config.RoleBudgetConfig(
          tokens_per_hour: -1,
          tool_calls_per_hour: -1,
        ),
      ),
    )
  support.with_runtime(cfg, fn() {
    let recorder = process.new_subject()
    let channel_registry =
      support.discord_start_registry(
        support.channel_config(),
        support.discord_handler(support.mock_config()),
        [support.discord_message_event("oi", "456")],
        recorder,
      )
    let assert Ok(record) = process.receive(recorder, within: 5000)
    record.content
    |> should.equal(cg_pure.budget_exhausted_reply(support.now))
    registry.stop_channels(channel_registry)
  })
}

pub fn long_reply_is_split_test() {
  support.with_runtime_root(cfg(["discord:456"]), fn(root) {
    support.seed_core(root, "discord:456", "Núcleo de teste.")
    let recorder = process.new_subject()
    let channel_registry =
      support.discord_start_registry(
        support.channel_config(),
        support.discord_handler(support.mock_config()),
        [support.discord_message_event("[long-response]", "456")],
        recorder,
      )
    let records = collect_records(recorder, [])
    should.equal(list.length(records) > 1, True)
    list.each(records, fn(record) {
      should.equal(string.length(record.content) <= 2000, True)
    })
    registry.stop_channels(channel_registry)
  })
}

pub fn llm_error_is_friendly_test() {
  support.with_runtime_root(cfg(["discord:456"]), fn(root) {
    support.seed_core(root, "discord:456", "Núcleo de teste.")
    let recorder = process.new_subject()
    let broken =
      provider.ProviderConfig(
        name: "missing-provider",
        api_key: None,
        base_url: None,
        default_model: "none",
      )
    let channel_registry =
      support.discord_start_registry(
        support.channel_config(),
        support.discord_handler(broken),
        [support.discord_message_event("oi", "456")],
        recorder,
      )
    support.await_content(recorder, "Provedor de IA")
    |> should.equal(True)
    registry.stop_channels(channel_registry)
  })
}

pub fn member_tools_hide_dangerous_tools_test() {
  let visible =
    cg_pure.tools_for(
      support.channel_config().capabilities,
      access_types.Member,
      executor.builtin_tools(),
    )
  let names = list.map(visible, fn(tool) { tool.name })
  should.equal(list.contains(names, "safe_shell"), False)
  should.equal(list.contains(names, "process"), False)
  should.equal(list.contains(names, "browser"), False)
  should.equal(list.contains(names, "gateway"), False)
}

// ============================================================================
// Live gateway (PRD-D, D-01 and D-02): the whole channel against the fake.
// ============================================================================

fn discord_status(channel_registry: registry.ChannelRegistry) {
  let assert Ok(status) =
    channel_health.snapshot(channel_registry.health, channel_health.now_ms())
    |> list.find(fn(status) { status.name == "discord" })
  status
}

fn await_discord_ready(
  channel_registry: registry.ChannelRegistry,
  ready: Bool,
  tries: Int,
) -> health_types.ChannelStatus {
  let status = discord_status(channel_registry)
  case status.ready == ready, tries {
    True, _ -> status
    False, 0 -> status
    False, _ -> {
      process.sleep(20)
      await_discord_ready(channel_registry, ready, tries - 1)
    }
  }
}

fn connect_to_fake(fake: discord_fake.Fake) -> process.Pid {
  let conn = discord_fake.expect_connection(fake, 3000)
  discord_fake.send_text(conn, discord_fake.hello(60_000))
  let _ = discord_fake.expect_op(fake, 2, 3000)
  discord_fake.send_text(
    conn,
    discord_fake.ready("sess-1", discord_fake.resume_url(fake), 1),
  )
  conn
}

pub fn live_gateway_message_reaches_the_agent_test() {
  support.with_runtime_root(cfg(["discord:456"]), fn(root) {
    support.seed_core(root, "discord:456", "Núcleo de teste.")
    let fake = discord_fake.start()
    let recorder = process.new_subject()
    let channel_registry =
      support.discord_start_registry_at(
        support.channel_config(),
        support.discord_handler(support.mock_config()),
        [],
        recorder,
        channel_kit.DiscordGatewayAt(
          gateway_url: fake.url,
          api_url: "http://127.0.0.1:9",
        ),
      )
    let conn = connect_to_fake(fake)
    discord_fake.send_text(
      conn,
      discord_fake.dispatch(
        "MESSAGE_CREATE",
        "{\"id\":\"m1\",\"channel_id\":\"dm1\",\"content\":\"oi\",\"timestamp\":\"2026-11-25T00:00:00Z\",\"author\":{\"id\":\"456\",\"username\":\"tester\",\"discriminator\":\"0\",\"bot\":false}}",
        2,
      ),
    )
    support.await_content(recorder, "Mock response")
    |> should.equal(True)
    registry.stop_channels(channel_registry)
  })
}

pub fn live_gateway_readiness_follows_the_connection_test() {
  support.with_runtime(cfg(["discord:456"]), fn() {
    let fake = discord_fake.start()
    let recorder = process.new_subject()
    let channel_registry =
      support.discord_start_registry_at(
        support.channel_config(),
        support.discord_handler(support.mock_config()),
        [],
        recorder,
        channel_kit.DiscordGatewayAt(
          gateway_url: fake.url,
          api_url: "http://127.0.0.1:9",
        ),
      )
    // Not ready before READY.
    discord_status(channel_registry).ready |> should.equal(False)

    let conn = connect_to_fake(fake)
    await_discord_ready(channel_registry, True, 100).ready
    |> should.equal(True)

    discord_fake.close(conn, 4014)
    let status = await_discord_ready(channel_registry, False, 100)
    status.ready |> should.equal(False)
    let assert option.Some(reason) = status.error
    string.contains(reason, "Message Content Intent") |> should.be_true
    registry.stop_channels(channel_registry)
  })
}
