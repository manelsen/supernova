//// Group Alerts — Actor
////
//// Stores dedup timestamps; deciding who to notify and delivering the
//// message stays with the closed-group runtime.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/core/alerts/group_pure
import supernova/core/safe_call

const call_timeout_ms = 2000

pub type GroupAlertsMessage {
  Take(
    reply_to: Subject(Bool),
    kind: group_pure.GroupAlertKind,
    subject: String,
    now: Int,
  )
  RecordDenial(reply_to: Subject(Bool), subject: String, now: Int)
  Stop(reply_to: Subject(Nil))
}

pub type GroupAlerts =
  Subject(GroupAlertsMessage)

fn handle_message(
  state: group_pure.AlertState,
  message: GroupAlertsMessage,
) -> actor.Next(group_pure.AlertState, GroupAlertsMessage) {
  case message {
    Take(reply_to, kind, subject, now) -> {
      let allowed = group_pure.should_send(state.dedup, kind, subject, now)
      let next_dedup = case allowed {
        True -> group_pure.record(state.dedup, kind, subject, now)
        False -> state.dedup
      }
      actor.send(reply_to, allowed)
      actor.continue(group_pure.AlertState(..state, dedup: next_dedup))
    }
    RecordDenial(reply_to, subject, now) -> {
      let #(next, crossed) = group_pure.record_denial(state, subject, now)
      actor.send(reply_to, crossed)
      actor.continue(next)
    }
    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

pub fn start() -> Result(GroupAlerts, actor.StartError) {
  case
    actor.new(group_pure.new_state())
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Claim the right to send an alert. Unavailable alerts fail closed (no spam).
pub fn take(
  alerts: GroupAlerts,
  kind: group_pure.GroupAlertKind,
  subject: String,
  now: Int,
) -> Bool {
  case safe_call.call(alerts, call_timeout_ms, Take(_, kind, subject, now)) {
    Ok(allowed) -> allowed
    Error(_) -> False
  }
}

/// Record a denied attempt; true when >5 denials happened in 10 minutes.
pub fn record_denial(alerts: GroupAlerts, subject: String, now: Int) -> Bool {
  case safe_call.call(alerts, call_timeout_ms, RecordDenial(_, subject, now)) {
    Ok(crossed) -> crossed
    Error(_) -> False
  }
}

pub fn stop(alerts: GroupAlerts) -> Nil {
  let _ = safe_call.call(alerts, call_timeout_ms, Stop)
  Nil
}
