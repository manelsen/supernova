//// Resource Ledger — Pure Types
////
//// Pure data structures for resource accounting. No FFI, no side effects.
//// These types define the domain model for tracking resource consumption per agent.

import gleam/dict.{type Dict}

// ============================================================================
// Types
// ============================================================================

/// Types of resources that can be tracked.
pub type ResourceType {
  /// LLM prompt tokens
  LLMTokensPrompt
  /// LLM completion tokens
  LLMTokensCompletion
  /// Tool calls (per tool name)
  ToolCall(tool_name: String)
  /// Storage read operations
  StorageRead
  /// Storage write operations
  StorageWrite
  /// CPU time in milliseconds
  CPUTimeMs
}

/// Resource consumption counters for a single agent.
pub type ResourceCounters {
  ResourceCounters(
    /// Total LLM prompt tokens consumed
    llm_tokens_prompt: Int,
    /// Total LLM completion tokens consumed
    llm_tokens_completion: Int,
    /// Tool calls by tool name → count
    tool_calls: Dict(String, Int),
    /// Storage read operations
    storage_reads: Int,
    /// Storage write operations
    storage_writes: Int,
    /// CPU time in milliseconds
    cpu_time_ms: Int,
  )
}

/// Errors that can occur in ledger operations.
pub type LedgerError {
  /// Agent not found
  AgentNotFound(agent_id: String)
  /// Quota exceeded
  QuotaExceeded(agent_id: String, resource: String, current: Int, limit: Int)
  /// Invalid resource amount (negative or zero)
  InvalidAmount(amount: Int)
}

/// Command pattern for I/O operations.
/// Pure functions return commands; the actor executes them.
pub type LedgerCommand {
  /// Write audit log entry
  WriteAudit(agent_id: String, resource: String, amount: Int, timestamp: Int)
  /// Emit a telemetry event
  EmitTelemetry(name: String, measurements: List(#(String, String)))
}

/// The ledger state maintained by the actor.
pub type LedgerState {
  LedgerState(
    /// Resource counters by agent ID
    counters: Dict(String, ResourceCounters),
  )
}
