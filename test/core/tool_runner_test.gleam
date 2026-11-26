//// The guard of each tool call (PRD-F, F-02): outcomes, time limit, the
//// worker that dies on its own, and the exit reasons the gateway reads.

import gleam/dynamic
import gleam/erlang/process
import gleam/string
import gleeunit/should
import supernova/core/tool_runner

pub fn a_call_that_answers_is_done_test() {
  tool_runner.run(1000, fn() { Ok("pronto") })
  |> should.equal(tool_runner.Done(Ok("pronto")))
  tool_runner.run(1000, fn() { Error("falhou") })
  |> should.equal(tool_runner.Done(Error("falhou")))
}

pub fn a_crash_becomes_an_error_test() {
  let assert tool_runner.Done(Error(reason)) =
    tool_runner.run(1000, fn() { panic as "quebrou" })
  string.starts_with(reason, "tool crashed:") |> should.be_true
}

pub fn a_worker_killed_from_outside_is_reported_test() {
  let assert tool_runner.Done(Error(reason)) =
    tool_runner.run(1000, fn() {
      process.kill(process.self())
      Ok("unreachable")
    })
  reason |> should.equal("tool stopped: killed")
}

pub fn a_worker_that_exits_abnormally_is_reported_test() {
  let assert tool_runner.Done(Error(reason)) =
    tool_runner.run(1000, fn() {
      process.send_abnormal_exit(process.self(), "motivo próprio")
      process.sleep_forever()
      Ok("unreachable")
    })
  string.contains(reason, "motivo próprio") |> should.be_true
}

pub fn the_time_limit_stops_the_worker_test() {
  let started = process.new_subject()
  tool_runner.run(50, fn() {
    process.send(started, process.self())
    process.sleep_forever()
    Ok("unreachable")
  })
  |> should.equal(tool_runner.TimedOut(50))
  let assert Ok(worker) = process.receive(started, 1000)
  wait_dead(worker, 1000) |> should.be_true
}

pub fn calls_started_together_are_awaited_in_any_order_test() {
  let slow =
    tool_runner.start(1000, fn() {
      process.sleep(40)
      Ok("lenta")
    })
  let fast = tool_runner.start(1000, fn() { Ok("rápida") })
  tool_runner.await(fast) |> should.equal(tool_runner.Done(Ok("rápida")))
  tool_runner.await(slow) |> should.equal(tool_runner.Done(Ok("lenta")))
}

pub fn stop_reasons_test() {
  tool_runner.stop_reason(process.Abnormal(dynamic.string("timeout")))
  |> should.equal(Ok("timeout"))
  tool_runner.stop_reason(process.Abnormal(dynamic.string("cancelled")))
  |> should.equal(Ok("cancelled"))
  tool_runner.stop_reason(process.Abnormal(dynamic.string("outro")))
  |> should.equal(Error(Nil))
  tool_runner.stop_reason(process.Abnormal(dynamic.int(1)))
  |> should.equal(Error(Nil))
  tool_runner.stop_reason(process.Killed) |> should.equal(Error(Nil))
  tool_runner.stop_reason(process.Normal) |> should.equal(Error(Nil))
}

fn wait_dead(pid: process.Pid, within: Int) -> Bool {
  case process.is_alive(pid), within <= 0 {
    False, _ -> True
    True, True -> False
    True, False -> {
      process.sleep(5)
      wait_dead(pid, within - 5)
    }
  }
}
