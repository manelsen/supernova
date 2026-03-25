//// Alerts — Actor
////
//// Singleton actor that monitors agents for operational issues.
//// Delegates pure logic to the pure module, executes side effects via FFI.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(alerts) = actor.start(scheduler, ledger)
//// let assert Ok(active) = actor.check(alerts)
//// let assert Ok(Nil) = actor.acknowledge(alerts, "agent_1_budget_warning_1234567890")
//// actor.stop(alerts)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import supernova/core/alerts/pure
import supernova/core/alerts/types.{
  type Alert, type AlertCommand, type AlertsError, type AlertsState,
  EmitTelemetry, LogAlert,
}
import supernova/core/kernel_scheduler/actor as scheduler_actor
import supernova/core/kernel_scheduler/types as scheduler_types
import supernova/core/resource_ledger/actor as ledger_actor

// ============================================================================
// FFI — Timestamp (Erlang)
// ============================================================================

/// Get current timestamp in milliseconds (Erlang FFI).
@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

/// Emit telemetry event (Erlang FFI).
@external(erlang, "supernova_telemetry_ffi", "write_event")
fn ffi_write_event(
  name: String,
  timestamp: Int,
  agent_id: String,
) -> Result(Nil, String)

// ============================================================================
// Types
// ============================================================================

/// Messages that the alerts actor handles.
pub type AlertsMessage {
  /// Check all agents for alert conditions
  Check(
    reply_to: Subject(Result(List(Alert), String)),
    scheduler: scheduler_actor.KernelSchedulerHandle,
    ledger: ledger_actor.ResourceLedger,
  )
  /// Acknowledge an alert by ID
  Acknowledge(reply_to: Subject(Result(Nil, AlertsError)), alert_id: String)
  /// Get all active (unacknowledged) alerts
  GetActiveAlerts(reply_to: Subject(List(Alert)))
  /// Get all alerts including acknowledged
  GetAllAlerts(reply_to: Subject(List(Alert)))
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running alerts actor.
pub type AlertsHandle =
  Subject(AlertsMessage)

// ============================================================================
// Command Execution
// ============================================================================

/// Execute a list of commands returned by pure functions.
fn execute_commands(commands: List(AlertCommand)) -> Nil {
  list.each(commands, fn(cmd) {
    case cmd {
      EmitTelemetry(alert_type, agent_id, severity, _measurements) -> {
        let event_name = "alerts." <> alert_type <> "." <> severity
        let _ = ffi_write_event(event_name, ffi_current_timestamp(), agent_id)
        Nil
      }
      LogAlert(alert) -> {
        let _ =
          ffi_write_event(
            "alerts.logged." <> types.alert_type_to_string(alert.alert_type),
            alert.timestamp,
            alert.agent_id,
          )
        Nil
      }
    }
  })
}

// ============================================================================
// Alert Checking Logic
// ============================================================================

/// Check a single agent for budget warning conditions.
fn check_budget_alerts(
  state: AlertsState,
  agent_id: String,
  budget_remaining: Int,
  budget_limit: Int,
  timestamp: Int,
) -> #(AlertsState, List(AlertCommand)) {
  case budget_limit > 0 {
    False -> #(state, [])
    True -> {
      let current_usage = budget_limit - budget_remaining
      case
        pure.create_budget_alert(
          agent_id,
          current_usage,
          budget_limit,
          timestamp,
        )
      {
        Ok(alert) -> {
          // Only add if not already present
          case pure.alert_exists(state, agent_id, alert.alert_type) {
            True -> #(state, [])
            False -> {
              let #(new_state, commands) = pure.add_alert(state, alert)
              execute_commands(commands)
              #(new_state, commands)
            }
          }
        }
        Error(_) -> #(state, [])
      }
    }
  }
}

/// Check a single agent for stall warning conditions.
fn check_stall_alerts(
  state: AlertsState,
  agent_info: scheduler_types.AgentInfo,
  timestamp: Int,
) -> #(AlertsState, List(AlertCommand)) {
  case agent_info.status {
    scheduler_types.Running -> {
      // For running agents, check if last_run is too old
      case
        pure.create_stall_alert(
          agent_info.agent_id,
          agent_info.last_run,
          timestamp,
        )
      {
        Ok(alert) -> {
          case pure.alert_exists(state, agent_info.agent_id, alert.alert_type) {
            True -> #(state, [])
            False -> {
              let #(new_state, commands) = pure.add_alert(state, alert)
              execute_commands(commands)
              #(new_state, commands)
            }
          }
        }
        Error(_) -> #(state, [])
      }
    }
    _ -> #(state, [])
  }
}

// ============================================================================
// Actor Handler
// ============================================================================

/// Handle incoming messages and update state.
fn handle_message(
  state: AlertsState,
  message: AlertsMessage,
) -> actor.Next(AlertsState, AlertsMessage) {
  case message {
    Check(reply_to, scheduler, _ledger) -> {
      let timestamp = ffi_current_timestamp()
      let agent_infos = scheduler_actor.status(scheduler)

      let new_state =
        list.fold(agent_infos, state, fn(current_state, agent_info) {
          // Check budget alerts
          let budget_limit = case agent_info.budget_remaining >= 0 {
            True -> agent_info.budget_remaining * 5
            False -> 0
          }
          let budget_remaining = agent_info.budget_remaining

          let #(s1, _) =
            check_budget_alerts(
              current_state,
              agent_info.agent_id,
              budget_remaining,
              budget_limit,
              timestamp,
            )

          // Check stall alerts
          let #(s2, _) = check_stall_alerts(s1, agent_info, timestamp)

          s2
        })

      let active_alerts = pure.get_active_alerts(new_state)
      execute_commands([])
      actor.send(reply_to, Ok(active_alerts))
      actor.continue(new_state)
    }

    Acknowledge(reply_to, alert_id) -> {
      case pure.acknowledge(state, alert_id) {
        Ok(#(new_state, commands)) -> {
          execute_commands(commands)
          actor.send(reply_to, Ok(Nil))
          actor.continue(new_state)
        }
        Error(e) -> {
          actor.send(reply_to, Error(e))
          actor.continue(state)
        }
      }
    }

    GetActiveAlerts(reply_to) -> {
      let alerts = pure.get_active_alerts(state)
      actor.send(reply_to, alerts)
      actor.continue(state)
    }

    GetAllAlerts(reply_to) -> {
      let alerts = pure.get_all_alerts(state)
      actor.send(reply_to, alerts)
      actor.continue(state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start the alerts actor.
pub fn start() -> Result(AlertsHandle, actor.StartError) {
  let initial_state = pure.initial_state()

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Check all agents for alert conditions and return active alerts.
pub fn check(
  alerts: AlertsHandle,
  scheduler: scheduler_actor.KernelSchedulerHandle,
  ledger: ledger_actor.ResourceLedger,
) -> Result(List(Alert), String) {
  actor.call(alerts, waiting: 5000, sending: Check(_, scheduler, ledger))
}

/// Acknowledge an alert by ID.
pub fn acknowledge(
  alerts: AlertsHandle,
  alert_id: String,
) -> Result(Nil, AlertsError) {
  actor.call(alerts, waiting: 5000, sending: Acknowledge(_, alert_id))
}

/// Get all active (unacknowledged) alerts.
pub fn get_active_alerts(alerts: AlertsHandle) -> List(Alert) {
  actor.call(alerts, waiting: 5000, sending: GetActiveAlerts)
}

/// Get all alerts including acknowledged ones.
pub fn get_all_alerts(alerts: AlertsHandle) -> List(Alert) {
  actor.call(alerts, waiting: 5000, sending: GetAllAlerts)
}

/// Stop the alerts actor.
pub fn stop(alerts: AlertsHandle) -> Nil {
  actor.call(alerts, waiting: 5000, sending: Stop)
}
