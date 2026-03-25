//// Alerts — Pure Types
////
//// Pure data structures for operational alerts. No FFI, no side effects.
//// Alerts are generated when agents approach limits or stall.

import gleam/dict.{type Dict}

// ============================================================================
// Types
// ============================================================================

/// Types of alerts that can be generated.
pub type AlertType {
  /// Agent is at or above 80% of its budget limit
  BudgetWarning
  /// Agent has been running for > 1 hour without activity
  StallWarning
  /// LLM has failed 3+ times consecutively
  LLMFailureChain
}

/// Severity levels for alerts.
pub type AlertSeverity {
  Info
  Warning
  Critical
}

/// A single alert instance.
pub type Alert {
  Alert(
    /// Unique alert identifier
    id: String,
    /// Type of alert
    alert_type: AlertType,
    /// Agent this alert is about
    agent_id: String,
    /// Severity level
    severity: AlertSeverity,
    /// Human-readable alert message
    message: String,
    /// When the alert was generated (ms timestamp)
    timestamp: Int,
    /// Whether the alert has been acknowledged
    acknowledged: Bool,
    /// Additional context (e.g., budget percentage, stall duration)
    context: Dict(String, String),
  )
}

/// Command pattern for I/O operations.
/// Pure functions return commands; the actor executes them.
pub type AlertCommand {
  /// Emit a telemetry event for the alert
  EmitTelemetry(
    alert_type: String,
    agent_id: String,
    severity: String,
    measurements: Dict(String, String),
  )
  /// Log the alert to the operational log
  LogAlert(alert: Alert)
}

/// The alerts state maintained by the actor.
pub type AlertsState {
  AlertsState(
    /// All active (unacknowledged) alerts indexed by id
    alerts: Dict(String, Alert),
    /// Maximum alerts to keep in state
    max_alerts: Int,
  )
}

/// Errors that can occur in alert operations.
pub type AlertsError {
  /// Alert not found
  AlertNotFound(alert_id: String)
  /// Invalid alert parameters
  InvalidAlert(reason: String)
}

// ============================================================================
// Default Values
// ============================================================================

/// Default maximum number of alerts to keep.
pub const default_max_alerts: Int = 1000

/// Budget warning threshold (80%).
pub const budget_warning_threshold: Int = 80

/// Stall warning threshold (1 hour in milliseconds).
pub const stall_warning_threshold_ms: Int = 3_600_000

/// LLM failure chain threshold.
pub const llm_failure_threshold: Int = 3

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert AlertType to a string representation.
pub fn alert_type_to_string(alert_type: AlertType) -> String {
  case alert_type {
    BudgetWarning -> "budget_warning"
    StallWarning -> "stall_warning"
    LLMFailureChain -> "llm_failure_chain"
  }
}

/// Convert AlertSeverity to a string representation.
pub fn severity_to_string(severity: AlertSeverity) -> String {
  case severity {
    Info -> "info"
    Warning -> "warning"
    Critical -> "critical"
  }
}

/// Convert string to AlertType (for parsing).
pub fn string_to_alert_type(s: String) -> Result(AlertType, AlertsError) {
  case s {
    "budget_warning" -> Ok(BudgetWarning)
    "stall_warning" -> Ok(StallWarning)
    "llm_failure_chain" -> Ok(LLMFailureChain)
    _ -> Error(InvalidAlert("Unknown alert type: " <> s))
  }
}

/// Convert string to AlertSeverity (for parsing).
pub fn string_to_severity(s: String) -> Result(AlertSeverity, AlertsError) {
  case s {
    "info" -> Ok(Info)
    "warning" -> Ok(Warning)
    "critical" -> Ok(Critical)
    _ -> Error(InvalidAlert("Unknown severity: " <> s))
  }
}
