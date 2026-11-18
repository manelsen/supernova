//// Rate Limit — Pure Sliding Window
////
//// Per-principal message rate limiting with an injected clock. No FFI, no
//// side effects: the caller owns the state (in an actor or in the access
//// actor) and passes the current timestamp.
////
//// ## Usage
////
//// ```gleam
//// let #(state, decision) = pure.check(pure.new_state(), 10, now)
//// ```

import gleam/list

/// Window length: one minute.
pub const window_ms: Int = 60_000

/// Sliding-window state for one principal.
///
/// `hits` holds accepted-message timestamps inside the current window.
/// `last_notice` is the timestamp of the last "too many messages" warning
/// (0 = never).
pub type RateState {
  RateState(hits: List(Int), last_notice: Int)
}

/// Outcome of a rate limit check.
pub type RateDecision {
  Allowed
  RateLimited(notify: Bool)
}

/// Empty rate limit state.
pub fn new_state() -> RateState {
  RateState(hits: [], last_notice: 0)
}

/// Check a message against the per-minute limit.
///
/// `limit` is the maximum number of accepted messages per sliding minute.
/// `-1` means unlimited and leaves the state untouched. Rejected messages are
/// not recorded, so a flood cannot extend its own window. The `notify` flag is
/// true at most once per minute.
pub fn check(
  state: RateState,
  limit: Int,
  now: Int,
) -> #(RateState, RateDecision) {
  case limit {
    -1 -> #(state, Allowed)
    _ -> {
      let hits = prune(state.hits, now)
      case list.length(hits) < limit {
        True -> #(
          RateState(hits: [now, ..hits], last_notice: state.last_notice),
          Allowed,
        )
        False -> {
          let notify = notice_due(state.last_notice, now)
          let next =
            RateState(hits: hits, last_notice: case notify {
              True -> now
              False -> state.last_notice
            })
          #(next, RateLimited(notify: notify))
        }
      }
    }
  }
}

/// Whether the once-per-minute warning may be sent.
fn notice_due(last_notice: Int, now: Int) -> Bool {
  case last_notice {
    0 -> True
    _ -> now - last_notice >= window_ms
  }
}

fn prune(hits: List(Int), now: Int) -> List(Int) {
  list.filter(hits, fn(hit) { now - hit < window_ms })
}
