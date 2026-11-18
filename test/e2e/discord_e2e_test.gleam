import e2e/e2e_support as support
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/channel/registry
import supernova/config
import supernova/core/access/types as access_types
import supernova/core/closed_group/pure as cg_pure
import supernova/core/executor
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
  recorder: process.Subject(registry.OutboundRecord),
  acc: List(registry.OutboundRecord),
) -> List(registry.OutboundRecord) {
  case process.receive(recorder, within: 500) {
    Ok(record) -> collect_records(recorder, [record, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

pub fn authorized_member_receives_reply_test() {
  support.with_runtime(cfg(["discord:456"]), fn() {
    let recorder = process.new_subject()
    let channel_registry =
      support.discord_start_registry(
        support.channel_config(),
        support.discord_handler(support.mock_config()),
        [support.discord_message_event("oi", "456")],
        recorder,
      )
    let assert Ok(record) = process.receive(recorder, within: 5000)
    string.contains(record.content, "Mock response") |> should.equal(True)
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
  support.with_runtime(cfg, fn() {
    let recorder = process.new_subject()
    let channel_registry =
      support.discord_start_registry(
        support.channel_config(),
        support.discord_handler(support.mock_config()),
        [support.discord_guild_message_event("oi", "456", "guild1")],
        recorder,
      )
    let assert Ok(record) = process.receive(recorder, within: 5000)
    string.contains(record.content, "Mock response") |> should.equal(True)
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
  support.with_runtime(cfg(["discord:456"]), fn() {
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
  support.with_runtime(cfg(["discord:456"]), fn() {
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
    let assert Ok(record) = process.receive(recorder, within: 5000)
    string.contains(record.content, "Provedor de IA") |> should.equal(True)
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
