import exception
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova
import supernova/config
import supernova/core/access/actor as access_actor
import supernova/core/access/types as access_types
import supernova/core/alerts/group_actor as alerts_actor
import supernova/core/audit_log/actor as audit_actor
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/budget_policy/types as budget_types
import supernova/core/closed_group/global as closed_group_global
import supernova/core/closed_group/pure
import supernova/core/closed_group/runtime as cg_runtime
import supernova/core/closed_group/types as cg_types
import supernova/core/executor
import supernova/core/instance_budget/actor as instance_budget
import supernova/core/principal
import supernova/core/rate_limit/actor as rate_limiter
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/core/syscall/actor as syscall_actor
import supernova/core/tool_dispatch
import supernova/llm/pricing
import supernova/llm/provider
import test_workspace

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ffi_ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn ffi_write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

const now = 1_700_000_000_000

fn base_config() -> config.Config {
  config.default_config()
}

fn config_with_access(
  admins: List(String),
  members: List(String),
  chats: List(String),
) -> config.Config {
  let base = base_config()
  config.Config(
    ..base,
    access: config.AccessConfig(
      mode: config.Allowlist,
      admins: admins,
      members: members,
      denied_reply: "Esta instância é privada.",
      allowed_chats: chats,
    ),
  )
}

fn test_runtime(
  cfg: config.Config,
  root: String,
  send_alert: fn(String, String) -> Nil,
) -> cg_types.Runtime {
  let assert Ok(access) =
    access_actor.start_with_clock(pure.access_config(cfg.access), root, fn() {
      now
    })
  let assert Ok(budget) =
    budget_actor.start_with_config(
      pure.budget_config(cfg.role_budgets.member),
      20,
    )
  let assert Ok(ledger) =
    ledger_actor.start_persistent_with_clock(root <> "/ledger", fn() { now })
  let assert Ok(rate) = rate_limiter.start_with_clock(fn() { now })
  let assert Ok(audit) = audit_actor.start(root <> "/audit")
  let assert Ok(instance) =
    instance_budget.start_with_clock(cfg.instance_budget.timezone, fn() { now })
  let assert Ok(alerts) = alerts_actor.start()
  let manifests =
    dict.from_list([
      #("member", pure.manifest_for(cfg.capabilities, access_types.Member)),
      #("admin", pure.manifest_for(cfg.capabilities, access_types.Admin)),
    ])
  let assert Ok(gateway) =
    syscall_actor.start_with_capabilities(
      None,
      Some(budget),
      Some(audit),
      manifests,
      fn(_, _) { Ok("tool-ok") },
    )

  cg_types.Runtime(
    config: cfg,
    access: access,
    budget: budget,
    ledger: ledger,
    gateway: gateway,
    rate: rate,
    audit: audit,
    instance_budget: instance,
    alerts: alerts,
    clock: fn() { now },
    send_alert: send_alert,
  )
}

fn with_runtime(cfg: config.Config, body: fn(cg_types.Runtime) -> a) -> a {
  with_runtime_alerts(cfg, fn(_, _) { Nil }, body)
}

fn with_runtime_alerts(
  cfg: config.Config,
  send_alert: fn(String, String) -> Nil,
  body: fn(cg_types.Runtime) -> a,
) -> a {
  test_workspace.with_isolated_workspace("closed-group", fn(root) {
    let runtime = test_runtime(cfg, root, send_alert)
    body(runtime)
  })
}

fn member_gate(rt: cg_types.Runtime) -> cg_types.GateResult {
  cg_runtime.gate(rt, "telegram", "123", "123", "oi")
}

pub fn default_allowlist_denies_everyone_test() {
  with_runtime(config_with_access([], [], []), fn(runtime) {
    case member_gate(runtime) {
      cg_types.Reply(text) -> should.equal(text, "Esta instância é privada.")
      _ -> should.fail()
    }
    case member_gate(runtime) {
      cg_types.Ignored(_) -> should.be_true(True)
      _ -> should.fail()
    }
  })
}

pub fn authorized_member_and_admin_pass_test() {
  with_runtime(
    config_with_access(["telegram:1"], ["telegram:123"], []),
    fn(runtime) {
      case member_gate(runtime) {
        // The context carries the machine key used by the gateway's
        // capability manifests, not the Portuguese display name.
        cg_types.Allowed(cg_types.PrincipalContext(role:, ..)) ->
          should.equal(role, "member")
        _ -> should.fail()
      }
      case cg_runtime.gate(runtime, "telegram", "1", "1", "oi") {
        cg_types.Allowed(cg_types.PrincipalContext(role:, ..)) ->
          should.equal(role, "admin")
        _ -> should.fail()
      }
    },
  )
}

pub fn eu_works_even_when_denied_test() {
  with_runtime(config_with_access([], [], []), fn(runtime) {
    case cg_runtime.gate(runtime, "telegram", "123", "123", "/eu") {
      cg_types.Reply(text) ->
        should.be_true(string.contains(text, "telegram:123"))
      _ -> should.fail()
    }
  })
}

pub fn group_requires_chat_allowlist_test() {
  let cfg = config_with_access(["telegram:1"], ["telegram:123"], [])
  with_runtime(cfg, fn(runtime) {
    cg_runtime.gate(runtime, "telegram", "-100", "123", "oi")
    |> should.equal(cg_types.Ignored("chat denied"))

    case
      cg_runtime.gate(
        runtime,
        "telegram",
        "-100",
        "1",
        "/acesso chat adicionar telegram:-100",
      )
    {
      cg_types.Reply(text) ->
        should.be_true(string.contains(text, "autorizado"))
      _ -> should.fail()
    }

    case cg_runtime.gate(runtime, "telegram", "-100", "123", "oi") {
      cg_types.Allowed(_) -> should.be_true(True)
      _ -> should.fail()
    }
  })
}

pub fn admin_report_requires_authorized_chat_test() {
  let cfg = config_with_access(["telegram:1"], ["telegram:123"], [])
  with_runtime(cfg, fn(runtime) {
    cg_runtime.gate(runtime, "telegram", "-100", "1", "/auditoria")
    |> should.equal(cg_types.Ignored("chat denied"))

    case
      cg_runtime.gate(
        runtime,
        "telegram",
        "-100",
        "1",
        "/acesso chat adicionar telegram:-100",
      )
    {
      cg_types.Reply(text) ->
        should.be_true(string.contains(text, "autorizado"))
      _ -> should.fail()
    }

    case cg_runtime.gate(runtime, "telegram", "-100", "1", "/auditoria") {
      cg_types.Reply(_) -> Nil
      _ -> should.fail()
    }
  })
}

pub fn admin_commands_persist_and_member_is_refused_test() {
  let cfg = config_with_access(["telegram:1"], [], [])
  with_runtime(cfg, fn(runtime) {
    case
      cg_runtime.gate(
        runtime,
        "telegram",
        "1",
        "1",
        "/acesso adicionar telegram:123",
      )
    {
      cg_types.Reply(text) ->
        should.be_true(string.contains(text, "Adicionado"))
      _ -> should.fail()
    }
    case member_gate(runtime) {
      cg_types.Allowed(_) -> should.be_true(True)
      _ -> should.fail()
    }
    case cg_runtime.gate(runtime, "telegram", "123", "123", "/acesso listar") {
      cg_types.Reply(text) -> should.equal(text, "Comando restrito a admins.")
      _ -> should.fail()
    }
    should.equal(
      list.contains(access_actor.list_members(runtime.access), "telegram:123"),
      True,
    )
  })
}

pub fn rate_limit_warns_once_and_drops_test() {
  let base = config_with_access(["telegram:1"], ["telegram:123"], [])
  let cfg =
    config.Config(
      ..base,
      rate_limit: config.RateLimitConfig(
        member: config.RoleRateLimitConfig(messages_per_minute: 2),
        admin: config.RoleRateLimitConfig(messages_per_minute: -1),
      ),
    )
  with_runtime(cfg, fn(runtime) {
    case member_gate(runtime) {
      cg_types.Allowed(_) -> should.be_true(True)
      _ -> should.fail()
    }
    case member_gate(runtime) {
      cg_types.Allowed(_) -> should.be_true(True)
      _ -> should.fail()
    }
    case member_gate(runtime) {
      cg_types.Reply(text) -> should.equal(text, pure.rate_limited_reply)
      _ -> should.fail()
    }
    case member_gate(runtime) {
      cg_types.Ignored(_) -> should.be_true(True)
      _ -> should.fail()
    }
  })
}

pub fn exhausted_budget_blocks_before_llm_test() {
  let base = config_with_access(["telegram:1"], ["telegram:123"], [])
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
  with_runtime(cfg, fn(runtime) {
    case member_gate(runtime) {
      cg_types.Reply(text) ->
        should.equal(text, pure.budget_exhausted_reply(now))
      _ -> should.fail()
    }
  })
}

pub fn usage_self_is_private_and_all_is_admin_test() {
  let cfg = config_with_access(["telegram:1"], ["telegram:123"], [])
  with_runtime(cfg, fn(runtime) {
    ledger_actor.record_llm_usage(
      runtime.ledger,
      "telegram:123",
      "mock",
      "mock-model",
      100,
      50,
      0.01,
    )
    case cg_runtime.gate(runtime, "telegram", "123", "123", "/uso") {
      cg_types.Reply(text) ->
        should.be_true(string.contains(text, "telegram:123"))
      _ -> should.fail()
    }
    case cg_runtime.gate(runtime, "telegram", "1", "1", "/uso todos") {
      cg_types.Reply(text) ->
        should.be_true(string.contains(text, "telegram:123"))
      _ -> should.fail()
    }
    case cg_runtime.gate(runtime, "telegram", "123", "123", "/uso todos") {
      cg_types.Reply(text) -> should.equal(text, "Comando restrito a admins.")
      _ -> should.fail()
    }
  })
}

pub fn instance_cap_blocks_even_admin_until_raised_test() {
  let base = config_with_access(["telegram:1"], [], [])
  let cfg =
    config.Config(
      ..base,
      instance_budget: config.InstanceBudgetConfig(
        daily_usd: 0.001,
        timezone: "UTC",
        reserve_output_tokens: 1000,
      ),
    )
  with_runtime(cfg, fn(runtime) {
    ledger_actor.record_llm_usage(
      runtime.ledger,
      "telegram:1",
      "mock",
      "m",
      1000,
      1000,
      10.0,
    )
    case cg_runtime.gate(runtime, "telegram", "1", "1", "oi") {
      cg_types.Reply(text) -> should.equal(text, pure.instance_cap_reply)
      _ -> should.fail()
    }
    case cg_runtime.gate(runtime, "telegram", "1", "1", "/teto liberar 20") {
      cg_types.Reply(text) -> should.be_true(string.contains(text, "elevado"))
      _ -> should.fail()
    }
    case cg_runtime.gate(runtime, "telegram", "1", "1", "oi") {
      cg_types.Allowed(_) -> should.be_true(True)
      _ -> should.fail()
    }
  })
}

pub fn member_cannot_raise_instance_cap_test() {
  with_runtime(
    config_with_access(["telegram:1"], ["telegram:123"], []),
    fn(runtime) {
      case
        cg_runtime.gate(runtime, "telegram", "123", "123", "/teto liberar 20")
      {
        cg_types.Reply(text) -> should.equal(text, "Comando restrito a admins.")
        _ -> should.fail()
      }
    },
  )
}

pub fn tools_are_filtered_by_role_test() {
  let cfg = config_with_access([], [], [])
  let member_tools =
    pure.tools_for(
      cfg.capabilities,
      access_types.Member,
      tool_dispatch.builtin_tools(),
    )
  let admin_tools =
    pure.tools_for(
      cfg.capabilities,
      access_types.Admin,
      tool_dispatch.builtin_tools(),
    )
  should.equal(
    list.any(member_tools, fn(tool) { tool.name == "safe_shell" }),
    False,
  )
  should.equal(
    list.any(admin_tools, fn(tool) { tool.name == "safe_shell" }),
    True,
  )
}

pub fn gateway_refuses_denied_capability_test() {
  with_runtime(config_with_access(["telegram:1"], [], []), fn(runtime) {
    case
      syscall_actor.invoke_tool(
        runtime.gateway,
        "telegram:1",
        "member",
        "safe_shell",
        "{\"command\":\"ls\"}",
      )
    {
      Error(reason) ->
        should.be_true(string.contains(reason, "capability_denied"))
      Ok(_) -> should.fail()
    }
    audit_actor.get_all(runtime.audit)
    |> list.any(fn(entry) {
      entry.operation == "capability_denied"
      && entry.agent_id == "telegram:1"
      && entry.target == "safe_shell"
    })
    |> should.equal(True)
    case
      syscall_actor.invoke_tool(
        runtime.gateway,
        "telegram:1",
        "admin",
        "safe_shell",
        "{\"command\":\"ls\"}",
      )
    {
      Ok(output) -> should.equal(output, "tool-ok")
      Error(_) -> should.fail()
    }
  })
}

pub fn audit_denial_is_recorded_test() {
  with_runtime(config_with_access([], [], []), fn(runtime) {
    let _ = member_gate(runtime)
    let entries = audit_actor.get_all(runtime.audit)
    should.be_true(
      list.any(entries, fn(entry) {
        entry.operation == "access_denied" && entry.agent_id == "telegram:123"
      }),
    )
  })
}

pub fn audit_query_is_admin_only_test() {
  with_runtime(
    config_with_access(["telegram:1"], ["telegram:123"], []),
    fn(runtime) {
      let _ = cg_runtime.gate(runtime, "telegram", "1", "1", "/auditoria 5")
      case cg_runtime.gate(runtime, "telegram", "123", "123", "/auditoria") {
        cg_types.Reply(text) -> should.equal(text, "Comando restrito a admins.")
        _ -> should.fail()
      }
    },
  )
}

pub fn access_actor_failure_fails_closed_test() {
  with_runtime(
    config_with_access(["telegram:1"], ["telegram:123"], []),
    fn(runtime) {
      access_actor.stop(runtime.access)
      case member_gate(runtime) {
        cg_types.Reply(text) -> should.equal(text, pure.fail_closed_reply)
        _ -> should.fail()
      }
      audit_actor.get_all(runtime.audit)
      |> list.any(fn(entry) { entry.operation == "fail_closed" })
      |> should.equal(True)
    },
  )
}

pub fn unknown_sender_is_ignored_test() {
  with_runtime(config_with_access([], [], []), fn(rt) {
    case cg_runtime.gate(rt, "telegram", "123", "", "oi") {
      cg_types.Ignored(_) -> should.be_true(True)
      _ -> should.fail()
    }
  })
}

pub fn principal_round_trip_test() {
  let assert Ok(parsed) = principal.parse("discord:456")
  should.equal(principal.principal_id(parsed), "discord:456")
  should.equal(principal.is_valid_id("slack:1"), False)
  should.equal(principal.is_valid_id("telegram:123"), True)
}

pub fn two_principals_in_same_chat_have_separate_budgets_test() {
  let base = config_with_access([], ["telegram:123", "telegram:456"], [])
  let cfg =
    config.Config(
      ..base,
      role_budgets: config.RoleBudgetsConfig(
        member: config.RoleBudgetConfig(
          tokens_per_hour: 10,
          tool_calls_per_hour: 10,
        ),
        admin: base.role_budgets.admin,
      ),
    )
  with_runtime(cfg, fn(runtime) {
    budget_actor.record_consumption(
      runtime.budget,
      "telegram:123",
      budget_types.BudgetTokens,
      20,
    )
    case cg_runtime.gate(runtime, "telegram", "123", "123", "oi") {
      cg_types.Reply(text) ->
        should.equal(text, pure.budget_exhausted_reply(now))
      _ -> should.fail()
    }
    case cg_runtime.gate(runtime, "telegram", "456", "456", "oi") {
      cg_types.Allowed(context) ->
        context.principal_id |> should.equal("telegram:456")
      _ -> should.fail()
    }
  })
}

pub fn budget_actor_failure_fails_closed_test() {
  with_runtime(
    config_with_access(["telegram:1"], ["telegram:123"], []),
    fn(runtime) {
      budget_actor.stop(runtime.budget)
      case member_gate(runtime) {
        cg_types.Reply(text) -> should.equal(text, pure.fail_closed_reply)
        _ -> should.fail()
      }
    },
  )
}

pub fn ledger_failure_fails_closed_test() {
  with_runtime(
    config_with_access(["telegram:1"], ["telegram:123"], []),
    fn(runtime) {
      ledger_actor.stop(runtime.ledger)
      case member_gate(runtime) {
        cg_types.Reply(text) -> should.equal(text, pure.fail_closed_reply)
        _ -> should.fail()
      }
    },
  )
}

pub fn teto_accepts_integer_and_decimal_amounts_test() {
  pure.parse_teto_command("/teto liberar 20")
  |> should.equal(Some(pure.RaiseCap(20.0)))
  pure.parse_teto_command("/teto liberar 7.5")
  |> should.equal(Some(pure.RaiseCap(7.5)))
  pure.parse_teto_command("/teto liberar -1")
  |> should.equal(None)
}

pub fn two_principals_in_authorized_group_are_distinct_test() {
  let base = config_with_access([], ["telegram:123", "telegram:456"], [])
  let cfg =
    config.Config(
      ..base,
      access: config.AccessConfig(..base.access, allowed_chats: [
        "telegram:-1001",
      ]),
    )
  with_runtime(cfg, fn(runtime) {
    case cg_runtime.gate(runtime, "telegram", "-1001", "123", "oi") {
      cg_types.Allowed(context) ->
        context.principal_id |> should.equal("telegram:123")
      _ -> should.fail()
    }
    case cg_runtime.gate(runtime, "telegram", "-1001", "456", "oi") {
      cg_types.Allowed(context) ->
        context.principal_id |> should.equal("telegram:456")
      _ -> should.fail()
    }
  })
}

pub fn eu_reveals_group_chat_id_test() {
  with_runtime(config_with_access([], [], []), fn(runtime) {
    case cg_runtime.gate(runtime, "telegram", "-1001", "123", "/eu") {
      cg_types.Reply(text) ->
        should.be_true(string.contains(text, "telegram:-1001"))
      _ -> should.fail()
    }
  })
}

pub fn admin_with_unlimited_budget_is_never_blocked_test() {
  let base = config_with_access(["telegram:1"], [], [])
  with_runtime(base, fn(runtime) {
    budget_actor.record_consumption(
      runtime.budget,
      "telegram:1",
      budget_types.BudgetTokens,
      1_000_000,
    )
    case cg_runtime.gate(runtime, "telegram", "1", "1", "oi") {
      cg_types.Allowed(context) -> context.role |> should.equal("admin")
      _ -> should.fail()
    }
  })
}

pub fn audit_entries_never_contain_message_content_test() {
  with_runtime(config_with_access([], [], []), fn(runtime) {
    let _ =
      cg_runtime.gate(
        runtime,
        "telegram",
        "999",
        "999",
        "segredo-super-secreto",
      )
    audit_actor.get_all(runtime.audit)
    |> list.each(fn(entry) {
      string.contains(entry.details, "segredo-super-secreto")
      |> should.equal(False)
      string.contains(entry.target, "segredo-super-secreto")
      |> should.equal(False)
    })
  })
}

pub fn audit_query_respects_maximum_100_test() {
  with_runtime(config_with_access(["telegram:1"], [], []), fn(runtime) {
    list.repeat(Nil, 105)
    |> list.each(fn(_) {
      let _ = cg_runtime.gate(runtime, "telegram", "999", "999", "no")
    })
    case cg_runtime.gate(runtime, "telegram", "1", "1", "/auditoria 1000") {
      cg_types.Reply(text) ->
        text
        |> string.split("\n")
        |> list.filter(fn(line) { string.contains(line, " | ") })
        |> list.length
        |> should.equal(100)
      _ -> should.fail()
    }
  })
}

fn send_usage(
  runtime: cg_types.Runtime,
  principal_id: String,
  role: String,
  prompt_tokens: Int,
  completion_tokens: Int,
) -> Nil {
  let context =
    cg_runtime.run_context(
      runtime,
      cg_types.PrincipalContext(principal_id: principal_id, role: role),
    )
  case context.on_llm_usage {
    Some(record) ->
      record(
        "test-call:" <> int.to_string(unique_integer()),
        "mock",
        "m",
        prompt_tokens,
        completion_tokens,
      )
    None -> Nil
  }
}

pub fn budget_and_instance_alerts_are_deduplicated_test() {
  let base = config_with_access(["telegram:1"], [], [])
  let cfg =
    config.Config(
      ..base,
      role_budgets: config.RoleBudgetsConfig(
        member: config.RoleBudgetConfig(
          tokens_per_hour: 10,
          tool_calls_per_hour: 10,
        ),
        admin: base.role_budgets.admin,
      ),
      instance_budget: config.InstanceBudgetConfig(
        daily_usd: 1.0,
        timezone: "UTC",
        reserve_output_tokens: 1000,
      ),
    )
  let alert_recorder = process.new_subject()
  with_runtime_alerts(
    cfg,
    fn(admin, text) { process.send(alert_recorder, #(admin, text)) },
    fn(runtime) {
      send_usage(runtime, "telegram:123", "member", 8, 0)
      send_usage(runtime, "telegram:123", "member", 8, 0)
      let assert Ok(#(admin, budget_text)) =
        process.receive(alert_recorder, within: 1000)
      admin |> should.equal("telegram:1")
      string.contains(budget_text, "80%") |> should.equal(True)

      send_usage(runtime, "telegram:123", "member", 800_000, 0)
      let assert Ok(#(_, instance_text)) =
        process.receive(alert_recorder, within: 1000)
      string.contains(instance_text, "80%") |> should.equal(True)
      send_usage(runtime, "telegram:123", "member", 300_000, 0)
      let assert Ok(#(_, cap_text)) =
        process.receive(alert_recorder, within: 1000)
      string.contains(cap_text, "100%") |> should.equal(True)
      process.receive(alert_recorder, within: 100)
      |> should.equal(Error(Nil))
    },
  )
}

pub fn abuse_and_fail_closed_alerts_reach_every_admin_test() {
  let cfg = config_with_access(["telegram:1", "discord:2"], [], [])
  let alert_recorder = process.new_subject()
  with_runtime_alerts(
    cfg,
    fn(admin, text) { process.send(alert_recorder, #(admin, text)) },
    fn(runtime) {
      list.repeat(Nil, 6)
      |> list.each(fn(_) {
        let _ = cg_runtime.gate(runtime, "telegram", "999", "999", "no")
      })
      let assert Ok(#(first_admin, abuse_text)) =
        process.receive(alert_recorder, within: 1000)
      let assert Ok(#(second_admin, _)) =
        process.receive(alert_recorder, within: 1000)
      [first_admin, second_admin]
      |> list.sort(string.compare)
      |> should.equal(["discord:2", "telegram:1"])
      string.contains(abuse_text, "Mais de 5 tentativas") |> should.equal(True)

      access_actor.stop(runtime.access)
      let _ = cg_runtime.gate(runtime, "telegram", "123", "123", "oi")
      let assert Ok(#(_, failed_text)) =
        process.receive(alert_recorder, within: 1000)
      string.contains(failed_text, "Componente indisponível")
      |> should.equal(True)
    },
  )
}

pub fn commands_and_eu_bypass_rate_limit_test() {
  let base = config_with_access([], ["telegram:123"], [])
  let cfg =
    config.Config(
      ..base,
      rate_limit: config.RateLimitConfig(
        member: config.RoleRateLimitConfig(messages_per_minute: 1),
        admin: base.rate_limit.admin,
      ),
    )
  with_runtime(cfg, fn(runtime) {
    case cg_runtime.gate(runtime, "telegram", "123", "123", "oi") {
      cg_types.Allowed(_) -> Nil
      _ -> should.fail()
    }
    case cg_runtime.gate(runtime, "telegram", "123", "123", "oi") {
      cg_types.Reply(text) -> should.equal(text, pure.rate_limited_reply)
      _ -> should.fail()
    }
    list.repeat(Nil, 3)
    |> list.each(fn(_) {
      case cg_runtime.gate(runtime, "telegram", "123", "123", "/uso") {
        cg_types.Reply(text) ->
          should.be_true(string.contains(text, "Última hora"))
        _ -> should.fail()
      }
    })
    case cg_runtime.gate(runtime, "telegram", "-1001", "123", "/eu") {
      cg_types.Reply(text) ->
        should.be_true(string.contains(text, "telegram:-1001"))
      _ -> should.fail()
    }
  })
}

pub fn supervisor_fails_when_workspace_policy_cannot_start_test() {
  test_workspace.with_isolated_workspace("workspace-fail", fn(root) {
    use <- exception.defer(closed_group_global.clear_runtime)
    process.trap_exits(True)
    use <- exception.defer(fn() { process.trap_exits(False) })
    let data = root <> "/data"
    let assert Ok(_) = ffi_ensure_dir(data)
    let assert Ok(_) = ffi_write_file(data <> "/workspace", "not a directory")
    let cfg = config.Config(..config_with_access([], [], []), data_dir: data)

    case supernova.start_closed_group_supervisor(cfg) {
      Error(reason) ->
        should.be_true(string.contains(reason, "workspace policy"))
      Ok(_) -> should.fail()
    }
  })
}

pub fn supervisor_restarts_policy_actors_test() {
  test_workspace.with_isolated_workspace("closed-group-sup", fn(root) {
    use <- exception.defer(closed_group_global.clear_runtime)
    let base = config_with_access(["telegram:1"], [], [])
    let cfg = config.Config(..base, data_dir: root)
    let ready = process.new_subject()
    let _holder =
      process.spawn_unlinked(fn() {
        let result = supernova.start_closed_group_supervisor(cfg)
        process.send(ready, result)
        process.sleep(600_000)
      })
    let assert Ok(Ok(_supervisor)) = process.receive(ready, within: 5000)
    let assert Some(runtime) = closed_group_global.get_runtime()

    let assert Ok(access_pid) = process.subject_owner(runtime.access)
    process.kill(access_pid)
    process.sleep(1000)
    let assert Some(after_access) = closed_group_global.get_runtime()
    case cg_runtime.gate(after_access, "telegram", "1", "1", "oi") {
      cg_types.Allowed(_) -> Nil
      _ -> should.fail()
    }

    let assert Ok(budget_pid) = process.subject_owner(after_access.budget)
    process.kill(budget_pid)
    process.sleep(1000)
    let assert Some(after_budget) = closed_group_global.get_runtime()
    case cg_runtime.gate(after_budget, "telegram", "1", "1", "oi") {
      cg_types.Allowed(_) -> Nil
      _ -> should.fail()
    }

    let assert Ok(ledger_pid) = process.subject_owner(after_budget.ledger)
    process.kill(ledger_pid)
    process.sleep(1000)
    let assert Some(after_ledger) = closed_group_global.get_runtime()
    case cg_runtime.gate(after_ledger, "telegram", "1", "1", "oi") {
      cg_types.Allowed(_) -> Nil
      _ -> should.fail()
    }
  })
}

pub fn audit_principal_filter_test() {
  with_runtime(config_with_access(["telegram:1"], [], []), fn(runtime) {
    let _ = cg_runtime.gate(runtime, "telegram", "999", "999", "no")
    let _ = cg_runtime.gate(runtime, "telegram", "888", "888", "no")
    case
      cg_runtime.gate(runtime, "telegram", "1", "1", "/auditoria telegram:999")
    {
      cg_types.Reply(text) -> {
        should.be_true(string.contains(text, "telegram:999"))
        should.equal(string.contains(text, "telegram:888"), False)
      }
      _ -> should.fail()
    }
  })
}

pub fn admission_uses_routed_model_price_test() {
  let base = config_with_access(["telegram:1"], ["telegram:123"], [])
  let cheap = config.PricingEntry(input_per_mtok: 0.01, output_per_mtok: 0.01)
  let expensive =
    config.PricingEntry(input_per_mtok: 1000.0, output_per_mtok: 2000.0)
  let provider = fn(model: String) {
    config.ProviderConfig(
      provider: config.OpenAI,
      api_key: None,
      base_url: None,
      model: Some(model),
      timeout_ms: 1000,
    )
  }
  let cfg =
    config.Config(
      ..base,
      providers: dict.from_list([
        #("cheap", provider("cheap-model")),
        #("mock", provider("expensive-model")),
      ]),
      pricing: config.PricingConfig(
        default: cheap,
        models: dict.from_list([#("expensive-model", expensive)]),
      ),
      instance_budget: config.InstanceBudgetConfig(
        daily_usd: 0.05,
        timezone: "UTC",
        reserve_output_tokens: 1000,
      ),
    )
  with_runtime(cfg, fn(runtime) {
    let context =
      cg_runtime.run_context(
        runtime,
        cg_types.PrincipalContext(principal_id: "telegram:123", role: "member"),
      )
    let assert Some(admit) = context.admit_llm
    admit("call-cheap", "mock", "cheap-model", 100)
    |> should.be_ok()
    admit("call-expensive", "mock", "expensive-model", 100)
    |> should.be_error()
  })
}

pub fn network_failure_once_is_unconfirmed_and_retried_test() {
  with_runtime(
    config_with_access(["telegram:1"], ["telegram:123"], []),
    fn(runtime) {
      let context =
        cg_runtime.run_context(
          runtime,
          cg_types.PrincipalContext(
            principal_id: "telegram:123",
            role: "member",
          ),
        )
      let config =
        provider.ProviderConfig(
          name: "mock",
          api_key: None,
          base_url: None,
          default_model: "mock-model",
        )
      let assert Ok(_) =
        executor.run_with_context(
          [provider.user_message("simulate [mock-network-fail-once]")],
          config,
          [],
          context,
        )

      let usage = ledger_actor.get_all_usage(runtime.ledger)
      list.length(usage) |> should.equal(2)
      let day = pricing.day_key(now, "UTC")
      { ledger_actor.get_daily_cost(runtime.ledger, day) >. 0.0 }
      |> should.be_true()
    },
  )
}

pub fn retry_429_releases_every_reservation_test() {
  with_runtime(
    config_with_access(["telegram:1"], ["telegram:123"], []),
    fn(runtime) {
      let context =
        cg_runtime.run_context(
          runtime,
          cg_types.PrincipalContext(
            principal_id: "telegram:123",
            role: "member",
          ),
        )
      let config =
        provider.ProviderConfig(
          name: "mock",
          api_key: None,
          base_url: None,
          default_model: "mock-model",
        )
      case
        executor.run_with_context(
          [provider.user_message("simulate [mock-429]")],
          config,
          [],
          context,
        )
      {
        Error(executor.LLMError(reason: provider.APIError(status: 429, ..))) ->
          Nil
        other -> {
          let _ = other
          should.fail()
        }
      }
      list.length(ledger_actor.get_all_usage(runtime.ledger))
      |> should.equal(0)
      let day = pricing.day_key(now, "UTC")
      ledger_actor.get_daily_cost(runtime.ledger, day) |> should.equal(0.0)
    },
  )
}

pub fn retry_second_attempt_can_be_denied_by_cap_test() {
  let base = config_with_access(["telegram:1"], ["telegram:123"], [])
  let cfg =
    config.Config(
      ..base,
      pricing: config.PricingConfig(
        default: config.PricingEntry(
          input_per_mtok: 0.01,
          output_per_mtok: 0.01,
        ),
        models: dict.new(),
      ),
      instance_budget: config.InstanceBudgetConfig(
        daily_usd: 0.00002,
        timezone: "UTC",
        reserve_output_tokens: 1000,
      ),
    )
  with_runtime(cfg, fn(runtime) {
    let context =
      cg_runtime.run_context(
        runtime,
        cg_types.PrincipalContext(principal_id: "telegram:123", role: "member"),
      )
    let config =
      provider.ProviderConfig(
        name: "mock",
        api_key: None,
        base_url: None,
        default_model: "mock-model",
      )
    case
      executor.run_with_context(
        [provider.user_message("simulate [mock-network-fail-once]")],
        config,
        [],
        context,
      )
    {
      Error(executor.PolicyDenied(_)) -> Nil
      other -> {
        let _ = other
        should.fail()
      }
    }
    list.length(ledger_actor.get_all_usage(runtime.ledger))
    |> should.equal(1)
  })
}

pub fn usage_retry_uses_live_ledger_test() {
  with_runtime(
    config_with_access(["telegram:1"], ["telegram:123"], []),
    fn(runtime) {
      let stopped_ledger = runtime.ledger
      closed_group_global.set_ledger(stopped_ledger)
      ledger_actor.stop(stopped_ledger)
      let assert Ok(new_ledger) = ledger_actor.start()

      // Initial write goes to the stopped handle; swap the live ledger before
      // the first retry fires.
      send_usage(runtime, "telegram:123", "member", 10, 5)
      closed_group_global.set_ledger(new_ledger)

      let deadline = now + 4000
      wait_for_ledger_usage(new_ledger, deadline, runtime.clock)

      closed_group_global.set_ledger(stopped_ledger)
      ledger_actor.stop(new_ledger)
    },
  )
}

fn wait_for_ledger_usage(
  ledger: ledger_actor.ResourceLedger,
  deadline: Int,
  clock: fn() -> Int,
) -> Nil {
  case ledger_actor.get_all_usage(ledger) {
    [] ->
      case clock() >= deadline {
        True -> should.fail()
        False -> {
          process.sleep(50)
          wait_for_ledger_usage(ledger, deadline, clock)
        }
      }
    _ -> Nil
  }
}

pub fn alerts_only_reach_effective_admins_test() {
  let cfg = config_with_access(["telegram:1", "telegram:2"], [], [])
  let recorder = process.new_subject()
  with_runtime_alerts(
    cfg,
    fn(admin, text) { process.send(recorder, #(admin, text)) },
    fn(runtime) {
      runtime.access
      |> access_actor.remove_member("telegram:2")
      |> should.be_ok()

      cg_runtime.fail_closed_alert(runtime, "ledger")

      let assert Ok(#(admin, _)) = process.receive(recorder, within: 1000)
      admin |> should.equal("telegram:1")
      process.receive(recorder, within: 100)
      |> should.equal(Error(Nil))
    },
  )
}

pub fn alert_is_dropped_when_access_is_unavailable_test() {
  let cfg = config_with_access(["telegram:1"], [], [])
  let recorder = process.new_subject()
  with_runtime_alerts(
    cfg,
    fn(admin, text) { process.send(recorder, #(admin, text)) },
    fn(runtime) {
      access_actor.stop(runtime.access)
      cg_runtime.fail_closed_alert(runtime, "ledger")

      process.receive(recorder, within: 2500)
      |> should.equal(Error(Nil))
      audit_actor.get_all(runtime.audit)
      |> list.any(fn(entry) { entry.operation == "alert_dropped" })
      |> should.be_true()
    },
  )
}

pub fn denied_interaction_is_audited_test() {
  with_runtime(config_with_access(["telegram:1"], [], []), fn(runtime) {
    case cg_runtime.gate_interaction(runtime, "telegram", "1", "999") {
      cg_types.Reply(text) -> should.equal(text, "Esta instância é privada.")
      _ -> should.fail()
    }
    audit_actor.get_all(runtime.audit)
    |> list.any(fn(entry) { entry.operation == "access_denied" })
    |> should.be_true()
  })
}
