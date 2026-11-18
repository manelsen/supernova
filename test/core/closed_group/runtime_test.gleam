import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/config
import supernova/core/access/actor as access_actor
import supernova/core/access/types as access_types
import supernova/core/alerts/group_actor as alerts_actor
import supernova/core/audit_log/actor as audit_actor
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/budget_policy/types as budget_types
import supernova/core/closed_group/pure
import supernova/core/closed_group/runtime as cg_runtime
import supernova/core/closed_group/types as cg_types
import supernova/core/instance_budget/actor as instance_budget
import supernova/core/principal
import supernova/core/rate_limit/actor as rate_limiter
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/core/syscall/actor as syscall_actor
import supernova/core/tool_dispatch
import test_workspace

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

fn test_runtime(cfg: config.Config, root: String) -> cg_types.Runtime {
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
    send_alert: fn(_, _) { Nil },
  )
}

fn with_runtime(cfg: config.Config, body: fn(cg_types.Runtime) -> a) -> a {
  test_workspace.with_isolated_workspace("closed-group", fn(root) {
    let runtime = test_runtime(cfg, root)
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
        cg_types.Allowed(cg_types.PrincipalContext(role:, ..)) ->
          should.equal(role, "membro")
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
