//// Alerts — Pure Functions
////
//// Pure functions for operational alert generation. No FFI, no side effects.
//// Functions take state and return new state + commands for the actor to execute.
////
//// ## Usage
////
//// ```gleam
//// let state = pure.initial_state()
//// let alert = pure.create_budget_alert(state, "agent_1", 85, 100)
//// let #(new_state, commands) = pure.add_alert(state, alert)
//// ```

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import supernova/core/alerts/types.{
  type Alert, type AlertCommand, type AlertType, type AlertsError,
  type AlertsState, Alert, AlertNotFound, AlertsState, BudgetWarning, Critical,
  EmitTelemetry, LLMFailureChain, LogAlert, StallWarning, Warning,
  budget_warning_threshold, default_max_alerts, llm_failure_threshold,
  severity_to_string, stall_warning_threshold_ms,
}

// ============================================================================
// Public API
// ============================================================================

/// Create initial alerts state.
pub fn initial_state() -> AlertsState {
  AlertsState(alerts: dict.new(), max_alerts: default_max_alerts)
}

/// Create initial alerts state with custom max alerts.
pub fn initial_state_with_max(max_alerts: Int) -> AlertsState {
  AlertsState(alerts: dict.new(), max_alerts: max_alerts)
}

/// Generate a unique alert ID.
pub fn generate_alert_id(
  agent_id: String,
  alert_type: AlertType,
  timestamp: Int,
) -> String {
  agent_id
  <> "_"
  <> types.alert_type_to_string(alert_type)
  <> "_"
  <> int.to_string(timestamp)
}

/// Create a budget warning alert if agent is at or above 80% of budget.
///
/// Returns the alert if budget threshold is exceeded, otherwise None.
pub fn create_budget_alert(
  agent_id: String,
  current_usage: Int,
  budget_limit: Int,
  timestamp: Int,
) -> Result(Alert, Nil) {
  case budget_limit <= 0 {
    True -> Error(Nil)
    False -> {
      let percentage = { current_usage * 100 } / budget_limit
      case percentage >= budget_warning_threshold {
        True ->
          Ok(Alert(
            id: generate_alert_id(agent_id, BudgetWarning, timestamp),
            alert_type: BudgetWarning,
            agent_id: agent_id,
            severity: case percentage >= 95 {
              True -> Critical
              False -> Warning
            },
            message: "Agent "
              <> agent_id
              <> " is at "
              <> int.to_string(percentage)
              <> "% of budget ("
              <> int.to_string(current_usage)
              <> "/"
              <> int.to_string(budget_limit)
              <> ")",
            timestamp: timestamp,
            acknowledged: False,
            context: dict.from_list([
              #("percentage", int.to_string(percentage)),
              #("current_usage", int.to_string(current_usage)),
              #("budget_limit", int.to_string(budget_limit)),
            ]),
          ))
        False -> Error(Nil)
      }
    }
  }
}

/// Create a stall warning alert if agent has been running without activity for > 1 hour.
///
/// Returns the alert if stall threshold is exceeded, otherwise None.
pub fn create_stall_alert(
  agent_id: String,
  last_activity_timestamp: Int,
  current_timestamp: Int,
) -> Result(Alert, Nil) {
  let stall_duration = current_timestamp - last_activity_timestamp
  case stall_duration >= stall_warning_threshold_ms {
    True ->
      Ok(Alert(
        id: generate_alert_id(agent_id, StallWarning, current_timestamp),
        alert_type: StallWarning,
        agent_id: agent_id,
        severity: Warning,
        message: "Agent "
          <> agent_id
          <> " has been stalled for "
          <> format_duration(stall_duration),
        timestamp: current_timestamp,
        acknowledged: False,
        context: dict.from_list([
          #("stall_duration_ms", int.to_string(stall_duration)),
          #("last_activity", int.to_string(last_activity_timestamp)),
        ]),
      ))
    False -> Error(Nil)
  }
}

/// Create an LLM failure chain alert if there are 3+ consecutive failures.
///
/// Returns the alert if failure threshold is exceeded, otherwise None.
pub fn create_llm_failure_alert(
  agent_id: String,
  consecutive_failures: Int,
  timestamp: Int,
) -> Result(Alert, Nil) {
  case consecutive_failures >= llm_failure_threshold {
    True ->
      Ok(Alert(
        id: generate_alert_id(agent_id, LLMFailureChain, timestamp),
        alert_type: LLMFailureChain,
        agent_id: agent_id,
        severity: Critical,
        message: "Agent "
          <> agent_id
          <> " has "
          <> int.to_string(consecutive_failures)
          <> " consecutive LLM failures",
        timestamp: timestamp,
        acknowledged: False,
        context: dict.from_list([
          #("consecutive_failures", int.to_string(consecutive_failures)),
        ]),
      ))
    False -> Error(Nil)
  }
}

/// Add an alert to the state.
///
/// Returns updated state and commands for the actor to execute.
pub fn add_alert(
  state: AlertsState,
  alert: Alert,
) -> #(AlertsState, List(AlertCommand)) {
  let commands = [
    EmitTelemetry(
      alert_type: types.alert_type_to_string(alert.alert_type),
      agent_id: alert.agent_id,
      severity: severity_to_string(alert.severity),
      measurements: dict.from_list([
        #("timestamp", int.to_string(alert.timestamp)),
      ]),
    ),
    LogAlert(alert),
  ]

  // Add alert and trim if necessary
  let new_alerts = dict.insert(state.alerts, alert.id, alert)
  let trimmed_alerts = trim_alerts(new_alerts, state.max_alerts)

  #(AlertsState(alerts: trimmed_alerts, max_alerts: state.max_alerts), commands)
}

/// Acknowledge an alert by ID.
///
/// Returns updated state or an error if alert not found.
pub fn acknowledge(
  state: AlertsState,
  alert_id: String,
) -> Result(#(AlertsState, List(AlertCommand)), AlertsError) {
  case dict.get(state.alerts, alert_id) {
    Ok(alert) -> {
      let updated_alert = Alert(..alert, acknowledged: True)
      let new_alerts = dict.insert(state.alerts, alert_id, updated_alert)
      #(AlertsState(alerts: new_alerts, max_alerts: state.max_alerts), [])
      |> Ok
    }
    Error(_) -> Error(AlertNotFound(alert_id))
  }
}

/// Get all active (unacknowledged) alerts.
pub fn get_active_alerts(state: AlertsState) -> List(Alert) {
  state.alerts
  |> dict.values()
  |> list.filter(fn(a) { !a.acknowledged })
}

/// Get all alerts (including acknowledged).
pub fn get_all_alerts(state: AlertsState) -> List(Alert) {
  dict.values(state.alerts)
}

/// Get alerts for a specific agent.
pub fn get_alerts_by_agent(
  state: AlertsState,
  agent_id: String,
) -> List(Alert) {
  state.alerts
  |> dict.values()
  |> list.filter(fn(a) { a.agent_id == agent_id })
}

/// Get alerts by type.
pub fn get_alerts_by_type(
  state: AlertsState,
  alert_type: AlertType,
) -> List(Alert) {
  state.alerts
  |> dict.values()
  |> list.filter(fn(a) { a.alert_type == alert_type })
}

/// Get count of active alerts.
pub fn active_alert_count(state: AlertsState) -> Int {
  get_active_alerts(state)
  |> list.length()
}

/// Check if an alert already exists for the same agent and type.
///
/// Used to prevent duplicate alerts.
pub fn alert_exists(
  state: AlertsState,
  agent_id: String,
  alert_type: AlertType,
) -> Bool {
  state.alerts
  |> dict.values()
  |> list.any(fn(a) {
    a.agent_id == agent_id && a.alert_type == alert_type && !a.acknowledged
  })
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Format duration in milliseconds to a human-readable string.
fn format_duration(ms: Int) -> String {
  let total_seconds = ms / 1000
  let hours = total_seconds / 3600
  let minutes = { total_seconds % 3600 } / 60
  let seconds = total_seconds % 60

  case hours > 0 {
    True ->
      int.to_string(hours)
      <> "h "
      <> int.to_string(minutes)
      <> "m "
      <> int.to_string(seconds)
      <> "s"
    False ->
      case minutes > 0 {
        True -> int.to_string(minutes) <> "m " <> int.to_string(seconds) <> "s"
        False -> int.to_string(seconds) <> "s"
      }
  }
}

/// Trim alerts to keep only the most recent ones.
fn trim_alerts(
  alerts: Dict(String, Alert),
  max_alerts: Int,
) -> Dict(String, Alert) {
  let count = dict.size(alerts)
  case count > max_alerts {
    True -> {
      // Sort by timestamp and keep most recent
      alerts
      |> dict.values()
      |> list.sort(fn(a, b) { int.compare(b.timestamp, a.timestamp) })
      |> list.take(max_alerts)
      |> list.map(fn(a) { #(a.id, a) })
      |> dict.from_list()
    }
    False -> alerts
  }
}
