//// KernelAPI — Pure Functions
////
//// Pure functions for kernel introspection API. No FFI, no side effects.
//// Functions format data for LLM consumption and validate inputs.
//// The actor layer handles actual queries to kernel_scheduler, world_model, and audit_log.
////
//// ## Usage
////
//// ```gleam
//// let result = pure.status_from_summaries(agent_infos)
//// let result = pure.world_query_result(facts)
//// let result = pure.audit_result(entries)
//// let validated = pure.validate_set_priority("agent_1", High)
//// ```

import gleam/list
import gleam/string
import supernova/core/audit_log/types as audit_types
import supernova/core/kernel_api/types
import supernova/core/kernel_scheduler/types as scheduler_types
import supernova/core/world_model/types as world_model_types

// ============================================================================
// Operation Validation
// ============================================================================

/// Validate that a SetPriority operation has valid inputs.
pub fn validate_set_priority(
  agent_id: String,
  _priority: scheduler_types.SchedulerPriority,
) -> Result(Nil, String) {
  case string.is_empty(agent_id) {
    True -> Error("agent_id cannot be empty")
    False -> Ok(Nil)
  }
}

/// Validate that an AuditRecent operation has valid inputs.
pub fn validate_audit_recent(
  agent_id: String,
  limit: Int,
) -> Result(Nil, String) {
  case string.is_empty(agent_id) {
    True -> Error("agent_id cannot be empty")
    False ->
      case limit < 1 {
        True -> Error("limit must be at least 1")
        False -> Ok(Nil)
      }
  }
}

/// Validate that a WorldQuery operation has valid inputs.
pub fn validate_world_query(pattern: String) -> Result(Nil, String) {
  let _ = pattern
  Ok(Nil)
}

// ============================================================================
// Result Formatting
// ============================================================================

/// Format agent status summaries into a kernel API result string.
pub fn status_from_summaries(
  summaries: List(types.AgentStatusSummary),
) -> types.KernelApiResult {
  types.KernelApiOk(types.format_status_summary(summaries))
}

/// Format agent infos directly into a kernel API result string.
pub fn status_from_infos(
  infos: List(scheduler_types.AgentInfo),
) -> types.KernelApiResult {
  let summaries = list.map(infos, types.agent_info_to_summary)
  types.KernelApiOk(types.format_status_summary(summaries))
}

/// Format world model facts into a kernel API result string.
pub fn world_query_result(
  facts: List(world_model_types.Fact),
) -> types.KernelApiResult {
  types.KernelApiOk(types.format_facts(facts))
}

/// Format audit entries into a kernel API result string.
pub fn audit_result(
  entries: List(audit_types.AuditEntry),
) -> types.KernelApiResult {
  types.KernelApiOk(types.format_audit_entries(entries))
}

/// Format a set_priority result.
pub fn set_priority_result(agent_id: String) -> types.KernelApiResult {
  types.KernelApiOk("priority_updated:" <> agent_id)
}

/// Format an error into a kernel API result.
pub fn error_result(message: String) -> types.KernelApiResult {
  types.KernelApiError(message)
}

// ============================================================================
// Operation Parsing (for tool argument handling)
// ============================================================================

/// Parse a priority string to SchedulerPriority.
/// Returns Error for invalid priority strings.
pub fn parse_priority(
  s: String,
) -> Result(scheduler_types.SchedulerPriority, String) {
  case string.lowercase(s) {
    "critical" -> Ok(scheduler_types.Critical)
    "high" -> Ok(scheduler_types.High)
    "normal" -> Ok(scheduler_types.Normal)
    "low" -> Ok(scheduler_types.Low)
    other ->
      Error(
        "Unknown priority: "
        <> other
        <> ". Valid values: critical, high, normal, low",
      )
  }
}

/// Convert SchedulerPriority to string.
pub fn priority_to_string(p: scheduler_types.SchedulerPriority) -> String {
  case p {
    scheduler_types.Critical -> "critical"
    scheduler_types.High -> "high"
    scheduler_types.Normal -> "normal"
    scheduler_types.Low -> "low"
  }
}
