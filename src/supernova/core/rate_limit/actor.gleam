//// Rate Limit — Actor
////
//// Owns the per-principal sliding windows. Decisions come from
//// `supernova/core/rate_limit/pure`; the actor only stores state.

import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/core/rate_limit/pure
import supernova/core/safe_call

const call_timeout_ms = 2000

pub type RateMessage {
  Check(reply_to: Subject(pure.RateDecision), principal_id: String, limit: Int)
  Reset(reply_to: Subject(Nil), principal_id: String)
  Stop(reply_to: Subject(Nil))
}

pub type RateLimiter =
  Subject(RateMessage)

type State {
  State(windows: dict.Dict(String, pure.RateState), clock: fn() -> Int)
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_now() -> Int

fn handle_message(
  state: State,
  message: RateMessage,
) -> actor.Next(State, RateMessage) {
  case message {
    Check(reply_to, principal_id, limit) -> {
      let current = case dict.get(state.windows, principal_id) {
        Ok(window) -> window
        Error(_) -> pure.new_state()
      }
      let #(next, decision) = pure.check(current, limit, state.clock())
      actor.send(reply_to, decision)
      actor.continue(State(
        windows: dict.insert(state.windows, principal_id, next),
        clock: state.clock,
      ))
    }
    Reset(reply_to, principal_id) -> {
      actor.send(reply_to, Nil)
      actor.continue(State(
        windows: dict.delete(state.windows, principal_id),
        clock: state.clock,
      ))
    }
    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

/// Start the limiter with the system clock.
pub fn start() -> Result(RateLimiter, actor.StartError) {
  start_with_clock(ffi_now)
}

/// Start the limiter with an injected clock.
pub fn start_with_clock(
  clock: fn() -> Int,
) -> Result(RateLimiter, actor.StartError) {
  case
    actor.new(State(windows: dict.new(), clock: clock))
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Check one message. An unavailable limiter fails closed with a limited
/// decision, but suppresses the warning to avoid spamming.
pub fn check(
  limiter: RateLimiter,
  principal_id: String,
  limit: Int,
) -> pure.RateDecision {
  case safe_call.call(limiter, call_timeout_ms, Check(_, principal_id, limit)) {
    Ok(decision) -> decision
    Error(_) -> pure.RateLimited(notify: False)
  }
}

pub fn reset(limiter: RateLimiter, principal_id: String) -> Nil {
  case safe_call.call(limiter, call_timeout_ms, Reset(_, principal_id)) {
    Ok(_) -> Nil
    Error(_) -> Nil
  }
}

pub fn stop(limiter: RateLimiter) -> Nil {
  let _ = safe_call.call(limiter, call_timeout_ms, Stop)
  Nil
}
