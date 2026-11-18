//// Closed Group — Global runtime handle
////
//// Each supervised actor re-publishes its handle here on (re)start. The runtime
//// is assembled on demand, so a restarted child is picked up automatically.
//// Missing services mean the gate denies by default.

import gleam/list
import gleam/option.{type Option, None, Some}
import supernova/config
import supernova/core/access/actor as access_actor
import supernova/core/alerts/group_actor as alerts_actor
import supernova/core/audit_log/actor as audit_actor
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/closed_group/types
import supernova/core/instance_budget/actor as instance_budget
import supernova/core/rate_limit/actor as rate_limiter
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/core/syscall/actor as syscall_actor

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: any) -> Nil

@external(erlang, "supernova_global_ffi", "global_get")
fn global_get(key: String) -> any

@external(erlang, "supernova_global_ffi", "global_has")
fn global_has(key: String) -> Bool

@external(erlang, "supernova_global_ffi", "global_erase")
fn global_erase(key: String) -> Nil

const config_key = "supernova_global_cg_config"

const access_key = "supernova_global_cg_access"

const budget_key = "supernova_global_cg_budget"

const ledger_key = "supernova_global_cg_ledger"

const rate_key = "supernova_global_cg_rate"

const audit_key = "supernova_global_cg_audit"

const instance_key = "supernova_global_cg_instance"

const alerts_key = "supernova_global_cg_alerts"

const gateway_key = "supernova_global_cg_gateway"

const clock_key = "supernova_global_cg_clock"

const sender_key = "supernova_global_cg_sender"

const enforced_key = "supernova_global_cg_enforced"

pub fn set_config(config: config.Config) -> Nil {
  global_put(config_key, config)
}

pub fn set_access(access: access_actor.AccessActor) -> Nil {
  global_put(access_key, access)
}

pub fn set_budget(budget: budget_actor.BudgetPolicy) -> Nil {
  global_put(budget_key, budget)
}

pub fn set_ledger(ledger: ledger_actor.ResourceLedger) -> Nil {
  global_put(ledger_key, ledger)
}

pub fn set_rate(rate: rate_limiter.RateLimiter) -> Nil {
  global_put(rate_key, rate)
}

pub fn set_audit(audit: audit_actor.AuditLog) -> Nil {
  global_put(audit_key, audit)
}

pub fn set_instance_budget(budget: instance_budget.InstanceBudget) -> Nil {
  global_put(instance_key, budget)
}

pub fn set_alerts(alerts: alerts_actor.GroupAlerts) -> Nil {
  global_put(alerts_key, alerts)
}

pub fn set_gateway(gateway: syscall_actor.SyscallGateway) -> Nil {
  global_put(gateway_key, gateway)
}

pub fn set_clock(clock: fn() -> Int) -> Nil {
  global_put(clock_key, clock)
}

pub fn set_alert_sender(sender: fn(String, String) -> Nil) -> Nil {
  global_put(sender_key, sender)
}

/// Mark the runtime as production-enforced. When set, missing handles deny.
pub fn set_enforced(enforced: Bool) -> Nil {
  global_put(enforced_key, enforced)
}

pub fn is_enforced() -> Bool {
  case global_has(enforced_key) {
    True -> global_get(enforced_key)
    False -> False
  }
}

pub fn get_budget() -> Option(budget_actor.BudgetPolicy) {
  get_typed(budget_key)
}

pub fn get_audit() -> Option(audit_actor.AuditLog) {
  get_typed(audit_key)
}

/// Current clock in milliseconds; zero when no policy runtime is published.
pub fn now() -> Int {
  case get_typed(clock_key) {
    Some(clock) -> clock()
    None -> 0
  }
}

fn get_typed(key: String) -> Option(a) {
  case global_has(key) {
    True -> Some(global_get(key))
    False -> None
  }
}

/// Assemble the runtime from the currently published handles.
pub fn get_runtime() -> Option(types.Runtime) {
  case
    get_typed(config_key),
    get_typed(access_key),
    get_typed(budget_key),
    get_typed(ledger_key),
    get_typed(gateway_key),
    get_typed(rate_key),
    get_typed(audit_key),
    get_typed(instance_key),
    get_typed(alerts_key)
  {
    Some(config),
      Some(access),
      Some(budget),
      Some(ledger),
      Some(gateway),
      Some(rate),
      Some(audit),
      Some(instance_budget),
      Some(alerts)
    -> {
      let clock = case get_typed(clock_key) {
        Some(clock) -> clock
        None -> fn() { 0 }
      }
      let sender = case get_typed(sender_key) {
        Some(sender) -> sender
        None -> fn(_, _) { Nil }
      }
      Some(types.Runtime(
        config: config,
        access: access,
        budget: budget,
        ledger: ledger,
        gateway: gateway,
        rate: rate,
        audit: audit,
        instance_budget: instance_budget,
        alerts: alerts,
        clock: clock,
        send_alert: sender,
      ))
    }
    _, _, _, _, _, _, _, _, _ -> None
  }
}

/// Whether a group chat/server is explicitly authorized.
/// Missing runtime returns True (do not take destructive action without policy).
pub fn chat_authorized(chat_key: String) -> Bool {
  case get_runtime() {
    None -> True
    Some(runtime) ->
      list.contains(access_actor.list_chats(runtime.access), chat_key)
  }
}

/// Remove all published handles (tests and shutdown).
pub fn clear_runtime() -> Nil {
  [
    config_key,
    access_key,
    budget_key,
    ledger_key,
    rate_key,
    audit_key,
    instance_key,
    alerts_key,
    gateway_key,
    clock_key,
    sender_key,
    enforced_key,
  ]
  |> list.each(global_erase)
  global_erase(enforced_key)
}
