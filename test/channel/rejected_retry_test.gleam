//// A turn its lane refused (full lane, too many lanes) is not lost: it is
//// submitted again with growing waits; past about two minutes the person
//// gets one notice, and the attempts go on (PRD-E, E-01).

import gleam/erlang/process
import gleam/list
import gleeunit/should
import supernova/channel/channel_kit
import supernova/channel/chat_lanes

fn script(outcomes: List(chat_lanes.Outcome)) -> fn() -> chat_lanes.Outcome {
  let queue = process.new_subject()
  list.each(outcomes, process.send(queue, _))
  fn() {
    case process.receive(queue, 0) {
      Ok(outcome) -> outcome
      Error(Nil) -> chat_lanes.Rejected
    }
  }
}

fn drain(subject: process.Subject(a), acc: List(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(x) -> drain(subject, [x, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

pub fn accepted_on_a_later_try_without_notice_test() {
  let waits = process.new_subject()
  let notices = process.new_subject()
  channel_kit.retry_rejected(
    script([chat_lanes.Rejected, chat_lanes.Rejected, chat_lanes.Accepted]),
    fn(ms) { process.send(waits, ms) },
    fn() { process.send(notices, Nil) },
  )
  |> should.equal(channel_kit.Retried(chat_lanes.Accepted))
  drain(waits, []) |> should.equal([1000, 2000, 4000])
  drain(notices, []) |> should.equal([])
}

pub fn the_person_is_told_once_and_the_tries_go_on_test() {
  let waits = process.new_subject()
  let notices = process.new_subject()
  channel_kit.retry_rejected(
    script([]),
    fn(ms) { process.send(waits, ms) },
    fn() { process.send(notices, Nil) },
  )
  |> should.equal(channel_kit.GaveUp)
  let all = drain(waits, [])
  // About two minutes of growing waits before the notice...
  list.take(all, 7)
  |> should.equal([1000, 2000, 4000, 8000, 16_000, 32_000, 64_000])
  // ...then one try every two minutes, for twenty minutes more.
  list.drop(all, 7) |> list.all(fn(ms) { ms == 120_000 }) |> should.be_true()
  list.length(all) |> should.equal(17)
  drain(notices, []) |> should.equal([Nil])
}

pub fn shutdown_stops_the_tries_test() {
  let notices = process.new_subject()
  channel_kit.retry_rejected(
    script([chat_lanes.Rejected, chat_lanes.Draining]),
    fn(_) { Nil },
    fn() { process.send(notices, Nil) },
  )
  |> should.equal(channel_kit.Retried(chat_lanes.Draining))
  drain(notices, []) |> should.equal([])
}
