//// Instance Budget — Actor
////
//// Holds the current-day cap adjustment and a clock. No I/O.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/core/instance_budget/pure
import supernova/core/safe_call
import supernova/llm/pricing

const call_timeout_ms = 2000

pub type InstanceBudgetMessage {
  Check(
    reply_to: Subject(Result(Float, Float)),
    daily_usd: Float,
    spend_usd: Float,
  )
  Raise(reply_to: Subject(Float), daily_usd: Float, usd: Float)
  EffectiveCap(reply_to: Subject(Float), daily_usd: Float)
  Stop(reply_to: Subject(Nil))
}

pub type InstanceBudget =
  Subject(InstanceBudgetMessage)

type State {
  State(cap: pure.CapState, timezone: String, clock: fn() -> Int)
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_now() -> Int

fn today(state: State) -> String {
  pricing.day_key(state.clock(), state.timezone)
}

fn handle_message(
  state: State,
  message: InstanceBudgetMessage,
) -> actor.Next(State, InstanceBudgetMessage) {
  case message {
    Check(reply_to, daily_usd, spend_usd) -> {
      let day = today(state)
      let cap = pure.effective_cap(daily_usd, state.cap, day)
      let reply = case pure.reached(spend_usd, cap) {
        True -> Error(cap)
        False -> Ok(cap)
      }
      actor.send(reply_to, reply)
      actor.continue(state)
    }
    Raise(reply_to, daily_usd, usd) -> {
      let day = today(state)
      let next = pure.raise_cap(state.cap, day, usd)
      let cap = pure.effective_cap(daily_usd, next, day)
      actor.send(reply_to, cap)
      actor.continue(State(..state, cap: next))
    }
    EffectiveCap(reply_to, daily_usd) -> {
      let day = today(state)
      actor.send(reply_to, pure.effective_cap(daily_usd, state.cap, day))
      actor.continue(state)
    }
    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

pub fn start(timezone: String) -> Result(InstanceBudget, actor.StartError) {
  start_with_clock(timezone, ffi_now)
}

pub fn start_with_clock(
  timezone: String,
  clock: fn() -> Int,
) -> Result(InstanceBudget, actor.StartError) {
  let initial = State(cap: pure.new(""), timezone: timezone, clock: clock)
  case
    actor.new(initial)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Check the cap. On actor failure the cap is treated as reached.
pub fn check(
  budget: InstanceBudget,
  daily_usd: Float,
  spend_usd: Float,
) -> Result(Float, Float) {
  case safe_call.call(budget, call_timeout_ms, Check(_, daily_usd, spend_usd)) {
    Ok(result) -> result
    Error(_) -> Error(0.0)
  }
}

/// Raise the cap for the current day. Returns the new effective cap.
pub fn raise(budget: InstanceBudget, daily_usd: Float, usd: Float) -> Float {
  case safe_call.call(budget, call_timeout_ms, Raise(_, daily_usd, usd)) {
    Ok(cap) -> cap
    Error(_) -> daily_usd
  }
}

pub fn effective_cap(budget: InstanceBudget, daily_usd: Float) -> Float {
  case safe_call.call(budget, call_timeout_ms, EffectiveCap(_, daily_usd)) {
    Ok(cap) -> cap
    Error(_) -> daily_usd
  }
}

pub fn stop(budget: InstanceBudget) -> Nil {
  let _ = safe_call.call(budget, call_timeout_ms, Stop)
  Nil
}
