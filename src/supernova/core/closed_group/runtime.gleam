//// Closed Group — Runtime gate
////
//// All inbound messages pass here before any LLM, tool or memory work.
//// The gate enforces access, chat allowlists, rate limits, per-principal
//// budgets and the instance-wide daily cap, then handles admin commands.

import gleam/dict
import gleam/float
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/config
import supernova/core/access/actor as access_actor
import supernova/core/access/pure as access_pure
import supernova/core/access/types as access_types
import supernova/core/alerts/group_actor as alerts_actor
import supernova/core/alerts/group_pure as alerts_pure
import supernova/core/audit_log/actor as audit_actor
import supernova/core/audit_log/types as audit_types
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/budget_policy/types as budget_types
import supernova/core/closed_group/pure
import supernova/core/closed_group/types
import supernova/core/executor
import supernova/core/instance_budget/actor as instance_budget
import supernova/core/instance_budget/pure as instance_pure
import supernova/core/principal
import supernova/core/rate_limit/actor as rate_limiter
import supernova/core/rate_limit/pure as rate_pure
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/core/resource_ledger/types as ledger_types
import supernova/core/syscall/actor as syscall_actor
import supernova/llm/pricing
import supernova/llm/provider

// ============================================================================
// Gate
// ============================================================================

/// Gate one inbound message before any LLM or tool work.
pub fn gate(
  runtime: types.Runtime,
  channel: String,
  chat_id: String,
  user_id: String,
  content: String,
) -> types.GateResult {
  let now = runtime.clock()

  case principal.from_sender(channel, user_id) {
    Error(_) -> {
      io.println("warn: discarded message without an identifiable sender")
      types.Ignored("missing sender")
    }
    Ok(speaker) -> {
      let principal_id = principal.principal_id(speaker)
      let is_private = pure.is_private_chat(channel, chat_id)
      let chat_key = pure.chat_key(channel, chat_id)

      case pure.is_eu_command(content) {
        True -> types.Reply(pure.eu_reply(principal_id, chat_key, is_private))
        False -> {
          case access_actor.try_check(runtime.access, principal_id) {
            Error(_) -> fail_closed_gate(runtime, principal_id, "access")
            Ok(access_types.Denied) -> {
              audit_denied(runtime, principal_id, "access_denied", channel, now)
              maybe_abuse_alert(runtime, principal_id, now)
              case
                access_actor.take_denied_notice(runtime.access, principal_id)
              {
                True -> types.Reply(runtime.config.access.denied_reply)
                False -> types.Ignored("access denied")
              }
            }
            Ok(access_types.Allowed(role)) -> {
              case role {
                // Admins may manage the current chat even when it is not yet
                // authorized; other commands wait for the chat check.
                access_types.Admin ->
                  case handle_command(runtime, principal_id, role, content) {
                    Some(reply) -> types.Reply(reply)
                    None ->
                      after_chat(
                        runtime,
                        principal_id,
                        role,
                        content,
                        is_private,
                        chat_key,
                        now,
                      )
                  }
                access_types.Member ->
                  case
                    check_chat(runtime, principal_id, chat_key, is_private, now)
                  {
                    Error(_) -> types.Ignored("chat denied")
                    Ok(Nil) ->
                      case
                        handle_command(runtime, principal_id, role, content)
                      {
                        Some(reply) -> types.Reply(reply)
                        None ->
                          after_chat_allowed(runtime, principal_id, role, now)
                      }
                  }
              }
            }
          }
        }
      }
    }
  }
}

fn check_chat(
  runtime: types.Runtime,
  principal_id: String,
  chat_key: String,
  is_private: Bool,
  now: Int,
) -> Result(Nil, Nil) {
  case
    access_actor.check_chat(runtime.access, principal_id, chat_key, is_private)
  {
    access_types.ChatAllowed -> Ok(Nil)
    access_types.ChatDenied -> {
      case access_actor.take_chat_denied_notice(runtime.access, chat_key) {
        True -> {
          audit_denied(runtime, principal_id, "chat_denied", chat_key, now)
          maybe_abuse_alert(runtime, chat_key, now)
        }
        False -> Nil
      }
      Error(Nil)
    }
  }
}

fn after_chat(
  runtime: types.Runtime,
  principal_id: String,
  role: access_types.Role,
  content: String,
  is_private: Bool,
  chat_key: String,
  now: Int,
) -> types.GateResult {
  case check_chat(runtime, principal_id, chat_key, is_private, now) {
    Error(_) -> types.Ignored("chat denied")
    Ok(Nil) ->
      case handle_command(runtime, principal_id, role, content) {
        Some(reply) -> types.Reply(reply)
        None -> after_chat_allowed(runtime, principal_id, role, now)
      }
  }
}

fn after_chat_allowed(
  runtime: types.Runtime,
  principal_id: String,
  role: access_types.Role,
  now: Int,
) -> types.GateResult {
  case
    rate_limiter.check(
      runtime.rate,
      principal_id,
      pure.rate_limit_for(runtime.config.rate_limit, role),
    )
  {
    rate_pure.RateLimited(notify: True) -> types.Reply(pure.rate_limited_reply)
    rate_pure.RateLimited(notify: False) -> types.Ignored("rate limited")
    rate_pure.Allowed -> {
      let role_name = pure.role_name(role)
      let budget_config =
        pure.budget_config(pure.role_budget_config(
          runtime.config.role_budgets,
          role,
        ))
      budget_actor.set_budget(runtime.budget, principal_id, budget_config)
      case precheck(runtime, principal_id, now) {
        Error(reply) -> types.Reply(reply)
        Ok(Nil) ->
          types.Allowed(types.PrincipalContext(
            principal_id: principal_id,
            role: role_name,
          ))
      }
    }
  }
}

fn fail_closed_gate(
  runtime: types.Runtime,
  principal_id: String,
  component: String,
) -> types.GateResult {
  fail_closed_component(runtime, principal_id, component)
  types.Reply(pure.fail_closed_reply)
}

fn fail_closed_component(
  runtime: types.Runtime,
  principal_id: String,
  component: String,
) -> Nil {
  io.println(
    "error: fail_closed component="
    <> component
    <> " principal="
    <> principal_id,
  )
  audit_action(
    runtime,
    principal_id,
    "fail_closed",
    component,
    audit_types.AuditFailure,
    "component unavailable",
  )
  fail_closed_alert(runtime, component)
}

// ============================================================================
// Pre-LLM checks
// ============================================================================

/// Check per-principal tokens and the instance daily cap.
pub fn precheck(
  runtime: types.Runtime,
  principal_id: String,
  now: Int,
) -> Result(Nil, String) {
  case
    budget_actor.try_check(
      runtime.budget,
      principal_id,
      budget_types.BudgetTokens,
      1,
    )
  {
    Error(_) -> {
      fail_closed_component(runtime, principal_id, "budget_policy")
      Error(pure.fail_closed_reply)
    }
    Ok(Error(_)) -> Error(pure.budget_exhausted_reply(now))
    Ok(Ok(_)) ->
      case daily_spend(runtime) {
        Error(_) -> {
          fail_closed_component(runtime, principal_id, "resource_ledger")
          Error(pure.fail_closed_reply)
        }
        Ok(spend) ->
          case
            instance_budget.check(
              runtime.instance_budget,
              runtime.config.instance_budget.daily_usd,
              spend,
            )
          {
            Error(_) -> Error(pure.instance_cap_reply)
            Ok(_) -> Ok(Nil)
          }
      }
  }
}

/// Estimated cost of all LLM calls in the configured local day.
pub fn daily_spend(runtime: types.Runtime) -> Result(Float, Nil) {
  let today =
    pricing.day_key(runtime.clock(), runtime.config.instance_budget.timezone)
  case ledger_actor.try_get_all_usage(runtime.ledger) {
    Error(_) -> Error(Nil)
    Ok(events) ->
      events
      |> list.filter(fn(event) {
        case event {
          ledger_types.LLMUsage(timestamp: timestamp, ..) ->
            pricing.day_key(timestamp, runtime.config.instance_budget.timezone)
            == today
          ledger_types.ToolUsage(..) -> False
        }
      })
      |> list.fold(0.0, fn(total, event) {
        case event {
          ledger_types.LLMUsage(cost_usd: cost, ..) -> total +. cost
          ledger_types.ToolUsage(..) -> total
        }
      })
      |> Ok
  }
}

// ============================================================================
// Commands
// ============================================================================

fn handle_command(
  runtime: types.Runtime,
  principal_id: String,
  role: access_types.Role,
  content: String,
) -> Option(String) {
  let is_admin = role == access_types.Admin

  case access_pure.parse_command(content) {
    Some(command) ->
      Some(handle_access_command(runtime, principal_id, is_admin, command))
    None ->
      case pure.parse_usage_command(content) {
        Some(pure.UsageSelf) ->
          Some(pure.usage_self_reply(
            principal_id,
            ledger_actor.get_all_usage(runtime.ledger),
            runtime.clock(),
          ))
        Some(pure.UsageAll) ->
          case is_admin {
            True -> Some(usage_all_reply(runtime))
            False -> Some("Comando restrito a admins.")
          }
        None ->
          case pure.parse_teto_command(content) {
            Some(pure.RaiseCap(usd)) ->
              case is_admin {
                True -> Some(handle_teto(runtime, principal_id, usd))
                False -> Some("Comando restrito a admins.")
              }
            None ->
              case pure.parse_audit_command(content) {
                Some(query) ->
                  case is_admin {
                    True -> Some(handle_audit(runtime, query))
                    False -> Some("Comando restrito a admins.")
                  }
                None -> None
              }
          }
      }
  }
}

fn handle_access_command(
  runtime: types.Runtime,
  principal_id: String,
  is_admin: Bool,
  command: access_types.Command,
) -> String {
  case is_admin {
    False -> "Comando restrito a admins."
    True -> {
      let result = case command {
        access_types.ListAccess ->
          Ok(pure.access_list_reply(
            access_actor.list_admins(runtime.access),
            access_actor.list_members(runtime.access),
          ))
        access_types.ListChats ->
          Ok(pure.chat_list_reply(access_actor.list_chats(runtime.access)))
        access_types.AddAccess(target, role) ->
          case principal.is_valid_id(target) {
            False -> Error("principal inválido: use canal:user_id")
            True ->
              case access_actor.add_member(runtime.access, target, role) {
                Ok(_) ->
                  Ok(
                    "Adicionado "
                    <> target
                    <> " como "
                    <> pure.role_name(role)
                    <> ".",
                  )
                Error(reason) -> Error(reason)
              }
          }
        access_types.RemoveAccess(target) ->
          case access_actor.remove_member(runtime.access, target) {
            Ok(_) -> Ok("Removido " <> target <> ".")
            Error(reason) -> Error(reason)
          }
        access_types.AddChat(chat_id) ->
          case valid_chat_id(chat_id) {
            False ->
              Error("chat inválido: use telegram:<id> ou discord:guild:<id>")
            True ->
              case access_actor.add_chat(runtime.access, chat_id) {
                Ok(_) -> Ok("Chat autorizado: " <> chat_id)
                Error(reason) -> Error(reason)
              }
          }
        access_types.RemoveChat(chat_id) ->
          case access_actor.remove_chat(runtime.access, chat_id) {
            Ok(_) -> Ok("Chat removido: " <> chat_id)
            Error(reason) -> Error(reason)
          }
      }

      audit_command(runtime, principal_id, command)
      case result {
        Ok(text) -> text
        Error(reason) -> "Erro: " <> reason
      }
    }
  }
}

fn valid_chat_id(chat_id: String) -> Bool {
  case string.starts_with(chat_id, "telegram:") {
    True -> string.length(chat_id) > string.length("telegram:")
    False ->
      case string.starts_with(chat_id, "discord:guild:") {
        True -> string.length(chat_id) > string.length("discord:guild:")
        False -> False
      }
  }
}

fn usage_all_reply(runtime: types.Runtime) -> String {
  pure.usage_all_reply(
    ledger_actor.get_all_usage(runtime.ledger),
    runtime.clock(),
    result.unwrap(daily_spend(runtime), 0.0),
    instance_budget.effective_cap(
      runtime.instance_budget,
      runtime.config.instance_budget.daily_usd,
    ),
  )
}

fn handle_teto(
  runtime: types.Runtime,
  principal_id: String,
  usd: Float,
) -> String {
  let cap =
    instance_budget.raise(
      runtime.instance_budget,
      runtime.config.instance_budget.daily_usd,
      usd,
    )
  audit_action(
    runtime,
    principal_id,
    "teto_liberar",
    "instance",
    audit_types.AuditSuccess,
    "usd=" <> float_to_string(usd),
  )
  "Teto de hoje elevado para US$ " <> float_to_string(cap) <> "."
}

fn handle_audit(runtime: types.Runtime, query: pure.AuditQuery) -> String {
  pure.audit_reply(audit_actor.get_all(runtime.audit), query)
}

// ============================================================================
// Executor context
// ============================================================================

/// Build the executor context for one authorized turn.
pub fn run_context(
  runtime: types.Runtime,
  context: types.PrincipalContext,
) -> executor.RunContext {
  executor.RunContext(
    principal_id: context.principal_id,
    role: context.role,
    before_llm: Some(fn() {
      precheck(runtime, context.principal_id, runtime.clock())
    }),
    on_llm_usage: Some(fn(provider_name, model, prompt, completion) {
      record_llm_usage(
        runtime,
        context.principal_id,
        provider_name,
        model,
        prompt,
        completion,
      )
    }),
    invoke_tool: Some(fn(name, args) {
      syscall_actor.invoke_tool(
        runtime.gateway,
        context.principal_id,
        context.role,
        name,
        args,
      )
    }),
    on_tool_result: Some(fn(name, ok) {
      let _ =
        ledger_actor.try_record_tool_usage(
          runtime.ledger,
          context.principal_id,
          name,
          ok,
        )
      Nil
    }),
  )
}

/// Tools visible to the principal's role.
pub fn tools_for(
  runtime: types.Runtime,
  role: String,
  tools: List(provider.ToolDefinition),
) -> List(provider.ToolDefinition) {
  pure.tools_for(
    runtime.config.capabilities,
    pure.role_from_string(role),
    tools,
  )
}

fn record_llm_usage(
  runtime: types.Runtime,
  principal_id: String,
  provider_name: String,
  model: String,
  prompt_tokens: Int,
  completion_tokens: Int,
) -> Nil {
  let price =
    pricing.price_for(
      model,
      pricing.Price(
        input_per_mtok: runtime.config.pricing.default.input_per_mtok,
        output_per_mtok: runtime.config.pricing.default.output_per_mtok,
      ),
      model_prices(runtime.config.pricing.models),
    )
  let cost = pricing.cost_usd(price, prompt_tokens, completion_tokens)
  case
    ledger_actor.try_record_llm_usage(
      runtime.ledger,
      principal_id,
      provider_name,
      model,
      prompt_tokens,
      completion_tokens,
      cost,
    )
  {
    Ok(_) -> Nil
    Error(_) -> {
      audit_action(
        runtime,
        principal_id,
        "fail_closed",
        "ledger",
        audit_types.AuditFailure,
        "ledger unavailable while recording LLM usage",
      )
      fail_closed_alert(runtime, "ledger")
    }
  }

  budget_actor.record_consumption(
    runtime.budget,
    principal_id,
    budget_types.BudgetTokens,
    prompt_tokens + completion_tokens,
  )
  maybe_budget_alert(runtime, principal_id)
  maybe_instance_alert(runtime)
  Nil
}

fn model_prices(
  models: dict.Dict(String, config.PricingEntry),
) -> dict.Dict(String, pricing.Price) {
  models
  |> dict.to_list
  |> list.map(fn(entry) {
    let #(name, price) = entry
    #(
      name,
      pricing.Price(
        input_per_mtok: price.input_per_mtok,
        output_per_mtok: price.output_per_mtok,
      ),
    )
  })
  |> dict.from_list
}

// ============================================================================
// Alerts and audits
// ============================================================================

fn maybe_budget_alert(runtime: types.Runtime, principal_id: String) -> Nil {
  let role = case access_actor.check(runtime.access, principal_id) {
    access_types.Allowed(role) -> role
    access_types.Denied -> access_types.Member
  }
  let role_config = pure.role_budget_config(runtime.config.role_budgets, role)
  let limit = role_config.tokens_per_hour
  case limit > 0 {
    False -> Nil
    True -> {
      let consumed =
        budget_actor.get_consumption(
          runtime.budget,
          principal_id,
          budget_types.BudgetTokens,
        )
      case consumed * 100 / limit >= 80 {
        True -> {
          let text = pure.budget_alert_text(principal_id)
          dispatch_alert(runtime, alerts_pure.Budget80, principal_id, text)
        }
        False -> Nil
      }
    }
  }
}

fn maybe_instance_alert(runtime: types.Runtime) -> Nil {
  let cap = runtime.config.instance_budget.daily_usd
  case cap <=. 0.0 {
    True -> Nil
    False -> {
      let spend = result.unwrap(daily_spend(runtime), 0.0)
      let percent = instance_pure.percentage(spend, cap)
      case percent >=. 100.0 {
        True ->
          dispatch_alert(
            runtime,
            alerts_pure.Instance100,
            "instance",
            pure.instance_alert_text(100, cap),
          )
        False ->
          case percent >=. 80.0 {
            True ->
              dispatch_alert(
                runtime,
                alerts_pure.Instance80,
                "instance",
                pure.instance_alert_text(80, cap),
              )
            False -> Nil
          }
      }
    }
  }
}

fn maybe_abuse_alert(runtime: types.Runtime, subject: String, now: Int) -> Nil {
  case alerts_actor.record_denial(runtime.alerts, subject, now) {
    True ->
      dispatch_alert(
        runtime,
        alerts_pure.Abuse,
        subject,
        pure.abuse_alert_text(subject),
      )
    False -> Nil
  }
}

pub fn fail_closed_alert(runtime: types.Runtime, component: String) -> Nil {
  dispatch_alert(
    runtime,
    alerts_pure.FailClosed,
    component,
    pure.fail_closed_alert_text(component),
  )
}

fn dispatch_alert(
  runtime: types.Runtime,
  kind: alerts_pure.GroupAlertKind,
  subject: String,
  text: String,
) -> Nil {
  case alerts_actor.take(runtime.alerts, kind, subject, runtime.clock()) {
    False -> Nil
    True -> {
      let admins = case access_actor.list_admins(runtime.access) {
        [] -> runtime.config.access.admins
        admins -> admins
      }
      list.each(admins, fn(admin) { runtime.send_alert(admin, text) })
    }
  }
}

fn audit_denied(
  runtime: types.Runtime,
  agent_id: String,
  action: String,
  target: String,
  now: Int,
) -> Nil {
  let entry =
    audit_types.denied_entry(now, agent_id, action, target, "policy denied")
  audit_actor.log_entry(runtime.audit, entry)
}

fn audit_action(
  runtime: types.Runtime,
  agent_id: String,
  action: String,
  target: String,
  result: audit_types.AuditResult,
  details: String,
) -> Nil {
  let entry =
    audit_types.AuditEntry(
      timestamp: runtime.clock(),
      agent_id: agent_id,
      operation: action,
      target: target,
      result: result,
      details: details,
    )
  audit_actor.log_entry(runtime.audit, entry)
}

fn audit_command(
  runtime: types.Runtime,
  principal_id: String,
  command: access_types.Command,
) -> Nil {
  let #(action, target) = case command {
    access_types.ListAccess -> #("acesso_listar", "access")
    access_types.AddAccess(target, _) -> #("acesso_adicionar", target)
    access_types.RemoveAccess(target) -> #("acesso_remover", target)
    access_types.AddChat(target) -> #("acesso_chat_adicionar", target)
    access_types.RemoveChat(target) -> #("acesso_chat_remover", target)
    access_types.ListChats -> #("acesso_chat_listar", "access")
  }
  audit_action(
    runtime,
    principal_id,
    action,
    target,
    audit_types.AuditSuccess,
    "ok",
  )
}

fn float_to_string(value: Float) -> String {
  float.to_string(value)
}
