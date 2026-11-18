//// Instance Budget — Pure daily cap adjustment
////
//// The configured daily cap is in USD. `/teto liberar <usd>` raises the cap
//// for the current day only; at midnight the adjustment expires.

/// Per-day cap adjustment.
pub type CapState {
  CapState(day: String, extra_usd: Float)
}

/// Empty adjustment.
pub fn new(day: String) -> CapState {
  CapState(day: day, extra_usd: 0.0)
}

/// Current day's effective cap. `-1` remains unlimited.
pub fn effective_cap(
  daily_usd: Float,
  state: CapState,
  today: String,
) -> Float {
  case daily_usd == -1.0 {
    True -> -1.0
    False ->
      case state.day == today {
        True -> daily_usd +. state.extra_usd
        False -> daily_usd
      }
  }
}

/// Raise the cap for `today` by at least `usd`.
pub fn raise_cap(state: CapState, today: String, usd: Float) -> CapState {
  let base = case state.day == today {
    True -> state.extra_usd
    False -> 0.0
  }
  CapState(day: today, extra_usd: base +. usd)
}

/// Whether spend has reached the cap.
pub fn reached(spend_usd: Float, cap_usd: Float) -> Bool {
  case cap_usd == -1.0 {
    True -> False
    False -> spend_usd >=. cap_usd
  }
}

/// Percentage consumed, for alerting (0 when unlimited).
pub fn percentage(spend_usd: Float, cap_usd: Float) -> Float {
  case cap_usd <=. 0.0 {
    True -> 0.0
    False -> spend_usd /. cap_usd *. 100.0
  }
}
