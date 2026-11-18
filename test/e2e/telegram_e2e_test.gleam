import e2e/e2e_support as support
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/channel/registry
import supernova/config
import supernova/core/access/actor as access_actor
import supernova/core/access/types as access_types
import supernova/core/audit_log/actor as audit_actor
import supernova/core/closed_group/global as closed_group_global
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
  support.with_runtime(cfg(["telegram:123"]), fn() {
    let recorder = process.new_subject()
    let channel_registry =
      support.telegram_start_registry(
        support.channel_config(),
        support.telegram_handler(support.mock_config()),
        [support.telegram_update("123", "123", "oi")],
        recorder,
      )

    support.await_content(recorder, "Mock response")
    |> should.equal(True)
    registry.stop_channels(channel_registry)
  })
}

pub fn unauthorized_gets_denied_once_test() {
  support.with_runtime(cfg(["telegram:123"]), fn() {
    let recorder = process.new_subject()
    let channel_registry =
      support.telegram_start_registry(
        support.channel_config(),
        support.telegram_handler(support.mock_config()),
        [
          support.telegram_update("999", "999", "oi"),
          support.telegram_update("999", "999", "de novo"),
        ],
        recorder,
      )

    let assert Ok(record) = process.receive(recorder, within: 5000)
    record.content |> should.equal("Esta instância é privada.")
    process.receive(recorder, within: 400) |> should.equal(Error(Nil))
    registry.stop_channels(channel_registry)
  })
}

pub fn leaves_unauthorized_group_and_audits_test() {
  support.with_runtime(cfg(["telegram:123"]), fn() {
    let recorder = process.new_subject()
    let left = process.new_subject()
    let channel_registry =
      support.telegram_start_registry_with_leave(
        support.channel_config(),
        support.telegram_handler(support.mock_config()),
        [support.telegram_chat_member_update("-1001", "member")],
        recorder,
        left,
      )

    process.receive(left, within: 1000)
    |> should.equal(Ok("-1001"))
    let assert Some(audit) = closed_group_global.get_audit()
    wait_for_audit_entry(audit, "chat_denied", "telegram:-1001", 2000)
    registry.stop_channels(channel_registry)
  })
}

pub fn access_lookup_failure_does_not_leave_group_test() {
  support.with_runtime(cfg(["telegram:123"]), fn() {
    // A live subject owned by this test never replies, so the access call
    // times out instead of reporting an empty allowlist.
    let unresponsive: access_actor.AccessActor = process.new_subject()
    closed_group_global.set_access(unresponsive)

    let recorder = process.new_subject()
    let left = process.new_subject()
    let channel_registry =
      support.telegram_start_registry_with_leave(
        support.channel_config(),
        support.telegram_handler(support.mock_config()),
        [support.telegram_chat_member_update("-1001", "member")],
        recorder,
        left,
      )

    process.receive(left, within: 3000) |> should.equal(Error(Nil))

    let assert Some(audit) = closed_group_global.get_audit()
    wait_for_audit_operation(audit, "chat_check_failed", 2000)

    registry.stop_channels(channel_registry)
  })
}

fn wait_for_audit_operation(
  audit: audit_actor.AuditLog,
  operation: String,
  timeout_ms: Int,
) -> Nil {
  let deadline = monotonic_ms() + timeout_ms
  wait_for_audit_loop(audit, operation, "", deadline)
}

fn wait_for_audit_entry(
  audit: audit_actor.AuditLog,
  operation: String,
  target: String,
  timeout_ms: Int,
) -> Nil {
  let deadline = monotonic_ms() + timeout_ms
  wait_for_audit_loop(audit, operation, target, deadline)
}

fn wait_for_audit_loop(
  audit: audit_actor.AuditLog,
  operation: String,
  target: String,
  deadline: Int,
) -> Nil {
  let found =
    audit_actor.get_all(audit)
    |> list.any(fn(entry) {
      entry.operation == operation && { target == "" || entry.target == target }
    })
  case found {
    True -> Nil
    False -> {
      case monotonic_ms() < deadline {
        True -> {
          process.sleep(25)
          wait_for_audit_loop(audit, operation, target, deadline)
        }
        False -> should.fail()
      }
    }
  }
}

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

pub fn exhausted_budget_reply_test() {
  let base = cfg(["telegram:123"])
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
      support.telegram_start_registry(
        support.channel_config(),
        support.telegram_handler(support.mock_config()),
        [support.telegram_update("123", "123", "oi")],
        recorder,
      )

    let assert Ok(record) = process.receive(recorder, within: 5000)
    record.content |> should.equal(cg_pure.budget_exhausted_reply(support.now))
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

pub fn long_reply_is_split_test() {
  support.with_runtime(cfg(["telegram:123"]), fn() {
    let recorder = process.new_subject()
    let channel_registry =
      support.telegram_start_registry(
        support.channel_config(),
        support.telegram_handler(support.mock_config()),
        [support.telegram_update("123", "123", "[long-response]")],
        recorder,
      )

    let records = collect_records(recorder, [])
    should.equal(list.length(records) > 1, True)
    list.each(records, fn(record) {
      should.equal(string.length(record.content) <= 4096, True)
    })
    registry.stop_channels(channel_registry)
  })
}

pub fn llm_error_is_friendly_test() {
  support.with_runtime(cfg(["telegram:123"]), fn() {
    let recorder = process.new_subject()
    let broken =
      provider.ProviderConfig(
        name: "missing-provider",
        api_key: None,
        base_url: None,
        default_model: "none",
      )
    let channel_registry =
      support.telegram_start_registry(
        support.channel_config(),
        support.telegram_handler(broken),
        [support.telegram_update("123", "123", "oi")],
        recorder,
      )

    support.await_content(recorder, "Provedor de IA")
    |> should.equal(True)
    registry.stop_channels(channel_registry)
  })
}

pub fn denied_tool_is_not_in_member_list_test() {
  let tools = executor.builtin_tools()
  let visible =
    cg_pure.tools_for(
      support.channel_config().capabilities,
      access_types.Member,
      tools,
    )
  list.any(visible, fn(tool) { tool.name == "safe_shell" })
  |> should.equal(False)
}
