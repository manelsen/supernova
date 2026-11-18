//// Closed Group — Runtime types
////
//// The closed-group runtime owns every handle needed to gate an inbound
//// message before the LLM sees it.

import supernova/config
import supernova/core/access/actor as access_actor
import supernova/core/alerts/group_actor as alerts_actor
import supernova/core/audit_log/actor as audit_actor
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/instance_budget/actor as instance_budget
import supernova/core/rate_limit/actor as rate_limiter
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/core/syscall/actor as syscall_actor

/// Handles shared by the router and the executor.
pub type Runtime {
  Runtime(
    config: config.Config,
    access: access_actor.AccessActor,
    budget: budget_actor.BudgetPolicy,
    ledger: ledger_actor.ResourceLedger,
    gateway: syscall_actor.SyscallGateway,
    rate: rate_limiter.RateLimiter,
    audit: audit_actor.AuditLog,
    instance_budget: instance_budget.InstanceBudget,
    alerts: alerts_actor.GroupAlerts,
    clock: fn() -> Int,
    send_alert: fn(String, String) -> Nil,
  )
}

/// Authenticated principal plus role for the current turn.
pub type PrincipalContext {
  PrincipalContext(principal_id: String, role: String)
}

/// Result of the pre-LLM gate.
pub type GateResult {
  Allowed(context: PrincipalContext)
  Reply(content: String)
  Ignored(reason: String)
}

/// One authenticated request to execute a tool.
pub type ToolGateway {
  ToolGateway(
    gateway: syscall_actor.SyscallGateway,
    principal_id: String,
    role: String,
  )
}
