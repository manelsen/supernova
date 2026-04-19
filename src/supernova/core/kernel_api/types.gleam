//// KernelAPI — Pure Types
////
//// Pure types for kernel introspection API.
//// No FFI, no side effects.
////
//// Provides tools for agents to query system state:
//// - kernel.status: query running agents and their states
//// - kernel.world_query: query facts from the world model
//// - kernel.audit_recent: query recent audit entries
//// - kernel.set_priority: modify agent scheduling priority

import gleam/int
import gleam/list
import gleam/string
import supernova/core/audit_log/types.{type AuditEntry, result_to_string}
import supernova/core/kernel_scheduler/types as scheduler
import supernova/core/world_model/types as world_model

// ============================================================================
// Kernel API Operations
// ============================================================================

/// Operations supported by the kernel introspection API.
pub type KernelApiOp {
  /// Query status of all registered agents
  Status
  /// Query world model facts matching a pattern
  WorldQuery(pattern: String)
  /// Query recent audit entries for an agent
  AuditRecent(agent_id: String, limit: Int)
  /// Set the priority of a registered agent
  SetPriority(target_agent_id: String, priority: scheduler.SchedulerPriority)
}

// ============================================================================
// Kernel API Results
// ============================================================================

/// Result of a kernel API operation.
pub type KernelApiResult {
  /// Operation succeeded; data contains operation-specific output
  KernelApiOk(data: String)
  /// Operation failed
  KernelApiError(message: String)
}

/// Agent status summary for kernel.status output.
pub type AgentStatusSummary {
  AgentStatusSummary(
    agent_id: String,
    status: String,
    priority: String,
    budget_remaining: Int,
    last_run: Int,
  )
}

// ============================================================================
// Commands (pure → actor)
// ============================================================================

/// Commands returned by pure functions for the actor to execute.
pub type KernelApiCommand {
  /// No command needed — result is ready
  NoOp
}

// ============================================================================
// Tool Definitions
// ============================================================================

/// Names of the kernel API tools.
pub const kernel_status_tool: String = "kernel.status"

pub const kernel_world_query_tool: String = "kernel.world_query"

pub const kernel_audit_recent_tool: String = "kernel.audit_recent"

pub const kernel_set_priority_tool: String = "kernel.set_priority"

/// All kernel API tool names.
pub fn all_tool_names() -> List(String) {
  [
    kernel_status_tool,
    kernel_world_query_tool,
    kernel_audit_recent_tool,
    kernel_set_priority_tool,
  ]
}

// ============================================================================
// Formatting Helpers
// ============================================================================

/// Convert an AgentInfo to a human-readable status summary.
pub fn agent_info_to_summary(info: scheduler.AgentInfo) -> AgentStatusSummary {
  AgentStatusSummary(
    agent_id: info.agent_id,
    status: agent_status_to_string(info.status),
    priority: priority_to_string(info.priority),
    budget_remaining: info.budget_remaining,
    last_run: info.last_run,
  )
}

fn agent_status_to_string(status: scheduler.AgentStatus) -> String {
  case status {
    scheduler.Idle -> "idle"
    scheduler.Running -> "running"
    scheduler.Starved -> "starved"
    scheduler.Exhausted -> "exhausted"
  }
}

fn priority_to_string(priority: scheduler.SchedulerPriority) -> String {
  case priority {
    scheduler.Critical -> "critical"
    scheduler.High -> "high"
    scheduler.Normal -> "normal"
    scheduler.Low -> "low"
  }
}

/// Format a list of agent status summaries as JSON-like string.
pub fn format_status_summary(summaries: List(AgentStatusSummary)) -> String {
  case summaries {
    [] -> "[]"
    _ -> {
      let items =
        list.map(summaries, fn(s) {
          "{\"agent_id\":\""
          <> s.agent_id
          <> "\",\"status\":\""
          <> s.status
          <> "\",\"priority\":\""
          <> s.priority
          <> "\",\"budget_remaining\":"
          <> int.to_string(s.budget_remaining)
          <> ",\"last_run\":"
          <> int.to_string(s.last_run)
          <> "}"
        })
      "[" <> string.join(items, ",") <> "]"
    }
  }
}

/// Format a fact for world query output.
pub fn format_fact(fact: world_model.Fact) -> String {
  "{\"id\":\""
  <> fact.id
  <> "\",\"type\":\""
  <> fact_type_to_string(fact.fact_type)
  <> "\",\"content\":\""
  <> fact.content
  <> "\",\"author\":\""
  <> fact.author
  <> "\",\"confidence\":"
  <> float_to_string(fact.confidence)
  <> ",\"version\":"
  <> int.to_string(fact.version)
  <> ",\"created_at\":"
  <> int.to_string(fact.created_at)
  <> ",\"tombstone\":"
  <> case fact.tombstone {
    True -> "true"
    False -> "false"
  }
  <> "}"
}

fn fact_type_to_string(fact_type: world_model.FactType) -> String {
  case fact_type {
    world_model.FactEntity -> "entity"
    world_model.FactDecision -> "decision"
    world_model.FactConstraint -> "constraint"
    world_model.FactGoal -> "goal"
    world_model.FactRelationship -> "relationship"
  }
}

/// Format a list of facts.
pub fn format_facts(facts: List(world_model.Fact)) -> String {
  case facts {
    [] -> "[]"
    _ -> "[" <> string.join(list.map(facts, format_fact), ",") <> "]"
  }
}

/// Format an audit entry for output.
pub fn format_audit_entry(entry: AuditEntry) -> String {
  "{\"timestamp\":"
  <> int.to_string(entry.timestamp)
  <> ",\"agent_id\":\""
  <> entry.agent_id
  <> "\",\"operation\":\""
  <> entry.operation
  <> "\",\"target\":\""
  <> entry.target
  <> "\",\"result\":\""
  <> result_to_string(entry.result)
  <> "\",\"details\":\""
  <> entry.details
  <> "\"}"
}

/// Format a list of audit entries.
pub fn format_audit_entries(entries: List(AuditEntry)) -> String {
  case entries {
    [] -> "[]"
    _ -> "[" <> string.join(list.map(entries, format_audit_entry), ",") <> "]"
  }
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn float_to_string(f: Float) -> String {
  do_float_to_string(f)
}

@external(erlang, "supernova_ledger_ffi", "format_float")
fn do_float_to_string(f: Float) -> String
