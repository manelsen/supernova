//// Controllable clock used by the harness.
////
//// The process holds the current instant and only moves when `advance` is
//// called, so a scenario can simulate days without sleeping.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result

pub type Message {
  Read(reply_to: Subject(Int))
  Advance(by_ms: Int, reply_to: Subject(Int))
  Stop
}

pub type Clock {
  Clock(subject: Subject(Message))
}

pub fn start(initial_ms: Int) -> Result(Clock, actor.StartError) {
  actor.new(initial_ms)
  |> actor.on_message(fn(state, message) {
    case message {
      Read(reply_to) -> {
        process.send(reply_to, state)
        actor.continue(state)
      }
      Advance(by_ms, reply_to) -> {
        let next = state + by_ms
        process.send(reply_to, next)
        actor.continue(next)
      }
      Stop -> actor.stop()
    }
  })
  |> actor.start
  |> result.map(fn(started) { Clock(started.data) })
}

pub fn now(clock: Clock) -> Int {
  actor.call(clock.subject, waiting: 5000, sending: Read)
}

pub fn advance(clock: Clock, by_ms: Int) -> Int {
  actor.call(clock.subject, waiting: 5000, sending: Advance(by_ms, _))
}

/// A `fn() -> Int` view for `supernova.boot`.
pub fn as_fn(clock: Clock) -> fn() -> Int {
  fn() { now(clock) }
}

pub fn stop(clock: Clock) -> Nil {
  actor.send(clock.subject, Stop)
  Nil
}
