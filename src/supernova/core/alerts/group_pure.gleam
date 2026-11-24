//// Group Alerts — Pure deduplication
////
//// Admins receive at most one alert per kind and subject per hour.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list

/// Kind of closed-group alert.
pub type GroupAlertKind {
  Budget80
  Instance80
  Instance100
  Abuse
  FailClosed
  /// A channel lost its account or was suspended (PRD-C, C-04).
  ChannelDown
}

/// Dedup state: key → last sent timestamp.
pub type DedupState {
  DedupState(records: Dict(String, Int))
}

/// Actor state: dedup timestamps plus recent denial timestamps per subject.
pub type AlertState {
  AlertState(dedup: DedupState, denials: Dict(String, List(Int)))
}

/// One hour dedup window.
pub const window_ms: Int = 3_600_000

pub fn new() -> DedupState {
  DedupState(records: dict.new())
}

pub fn new_state() -> AlertState {
  AlertState(dedup: new(), denials: dict.new())
}

/// Record a denied attempt and report whether the abuse threshold was crossed.
///
/// Threshold: more than 5 denials in 10 minutes for the same subject.
pub fn record_denial(
  state: AlertState,
  subject: String,
  now: Int,
) -> #(AlertState, Bool) {
  let window_start = now - 600_000
  let previous = case dict.get(state.denials, subject) {
    Ok(times) -> times
    Error(_) -> []
  }
  let recent = list.filter(previous, fn(at) { at >= window_start })
  let next = list.append(recent, [now])
  let crossed = list.length(next) > 5
  let next_denials = case crossed {
    True -> dict.insert(state.denials, subject, [])
    False -> dict.insert(state.denials, subject, next)
  }
  #(AlertState(..state, denials: next_denials), crossed)
}

pub fn kind_name(kind: GroupAlertKind) -> String {
  case kind {
    Budget80 -> "budget80"
    Instance80 -> "instance80"
    Instance100 -> "instance100"
    Abuse -> "abuse"
    FailClosed -> "fail_closed"
    ChannelDown -> "channel_down"
  }
}

pub fn key(kind: GroupAlertKind, subject: String) -> String {
  kind_name(kind) <> ":" <> subject
}

/// Whether an alert may be sent now.
pub fn should_send(
  state: DedupState,
  kind: GroupAlertKind,
  subject: String,
  now: Int,
) -> Bool {
  case dict.get(state.records, key(kind, subject)) {
    Error(_) -> True
    Ok(last) -> now - last >= window_ms
  }
}

/// Record that an alert was sent.
pub fn record(
  state: DedupState,
  kind: GroupAlertKind,
  subject: String,
  now: Int,
) -> DedupState {
  DedupState(records: dict.insert(state.records, key(kind, subject), now))
}

/// Human-readable percentage suffix used in alert texts.
pub fn percent_text(percent: Int) -> String {
  int.to_string(percent) <> "%"
}
