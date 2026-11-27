//// Slots per tool and per agent (PRD-F, F-03, D2).

import exception
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import supernova/core/tool_runner
import supernova/core/tool_slots
import supernova/metrics/actor as metrics_actor
import supernova/metrics/global as metrics_global

fn in_slot(tool: String, agent: String, wait_ms: Int, work) {
  tool_runner.start_in_slot(
    5000,
    Some(tool_runner.SlotRequest(tool: tool, agent: agent, wait_ms: wait_ms)),
    work,
  )
}

pub fn limits_follow_d2_test() {
  tool_slots.limits_for("computador")
  |> should.equal(tool_slots.Limits(per_agent: 2, instance: 8))
  tool_slots.limits_for("web")
  |> should.equal(tool_slots.Limits(per_agent: 4, instance: 32))
  tool_slots.limits_for("web_fetch")
  |> should.equal(tool_slots.Limits(per_agent: 4, instance: 32))
  tool_slots.limits_for("agenda")
  |> should.equal(tool_slots.Limits(per_agent: 8, instance: 64))
}

/// Ten computer calls of one agent: at most two run at the same time.
pub fn one_agent_runs_at_most_two_computer_calls_test() {
  let seen = process.new_subject()
  let pending =
    list.repeat(Nil, 10)
    |> list.map(fn(_) {
      in_slot("computador", "slots-a", 5000, fn() {
        process.send(seen, tool_slots.running_for("computador", "slots-a"))
        process.sleep(30)
        Ok("feito")
      })
    })
  list.each(pending, fn(call) {
    tool_runner.await(call) |> should.equal(tool_runner.Done(Ok("feito")))
  })
  let counts = drain(seen, [])
  list.length(counts) |> should.equal(10)
  list.fold(counts, 0, int.max) |> should.equal(2)
  tool_slots.running_for("computador", "slots-a") |> should.equal(0)
}

/// Five agents with two calls each: at most eight in the instance.
pub fn the_instance_runs_at_most_eight_computer_calls_test() {
  let seen = process.new_subject()
  let pending =
    list.flat_map(["b1", "b2", "b3", "b4", "b5"], fn(agent) {
      list.map([1, 2], fn(_) {
        in_slot("computador", "slots-" <> agent, 5000, fn() {
          process.send(seen, tool_slots.running("computador"))
          process.sleep(40)
          Ok("feito")
        })
      })
    })
  list.each(pending, fn(call) { tool_runner.await(call) })
  let counts = drain(seen, [])
  list.length(counts) |> should.equal(10)
  should.be_true(list.fold(counts, 0, int.max) <= 8)
}

/// Without a slot in time, the call answers that the tool is busy and runs
/// nothing; another agent is not held by it.
pub fn a_full_tool_answers_busy_test() {
  // Each held call makes its own release subject (only its owner may
  // receive on it) and hands it to the test.
  let releases = process.new_subject()
  let held =
    [1, 2]
    |> list.map(fn(_) {
      in_slot("computador", "slots-c", 5000, fn() {
        let release = process.new_subject()
        process.send(releases, release)
        let _ = process.receive(release, 5000)
        Ok("liberado")
      })
    })
  let assert Ok(first) = process.receive(releases, 1000)
  let assert Ok(second) = process.receive(releases, 1000)

  let ran = process.new_subject()
  in_slot("computador", "slots-c", 100, fn() {
    process.send(ran, Nil)
    Ok("não devia rodar")
  })
  |> tool_runner.await
  |> should.equal(tool_runner.Done(Error(tool_slots.busy_message)))
  process.receive(ran, 50) |> should.equal(Error(Nil))

  // Another agent still runs at once.
  in_slot("computador", "slots-d", 100, fn() { Ok("outra agente") })
  |> tool_runner.await
  |> should.equal(tool_runner.Done(Ok("outra agente")))

  process.send(first, Nil)
  process.send(second, Nil)
  list.each(held, tool_runner.await)
  tool_slots.running_for("computador", "slots-c") |> should.equal(0)
}

/// The slot comes back when the call ends by its time limit.
pub fn a_timed_out_call_gives_its_slot_back_test() {
  tool_runner.start_in_slot(
    50,
    Some(tool_runner.SlotRequest("computador", "slots-e", 1000)),
    fn() {
      process.sleep_forever()
      Ok("unreachable")
    },
  )
  |> tool_runner.await
  |> should.equal(tool_runner.TimedOut(50))
  wait_until(fn() { tool_slots.running_for("computador", "slots-e") == 0 }, 200)
}

/// The slot comes back when the turn dies, and a turn that dies while
/// waiting never takes one.
pub fn a_dead_turn_gives_its_slot_back_test() {
  let turn =
    process.spawn_unlinked(fn() {
      in_slot("computador", "slots-f", 5000, fn() {
        process.sleep_forever()
        Ok("unreachable")
      })
      |> tool_runner.await
    })
  wait_until(fn() { tool_slots.running_for("computador", "slots-f") == 1 }, 200)
  process.kill(turn)
  wait_until(fn() { tool_slots.running_for("computador", "slots-f") == 0 }, 200)
}

fn drain(subject, acc) {
  case process.receive(subject, 0) {
    Ok(item) -> drain(subject, [item, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

/// Polls `check` up to `tries` times, 5 ms apart (no fixed sleep).
fn wait_until(check: fn() -> Bool, tries: Int) -> Nil {
  case check(), tries {
    True, _ -> Nil
    False, 0 -> panic as "condition never held"
    False, _ -> {
      process.sleep(5)
      wait_until(check, tries - 1)
    }
  }
}

// Telemetry (PRD-F, F-04): calls in flight, waiting, cut and cancelled.

fn with_metrics(body: fn(metrics_actor.Metrics) -> a) -> a {
  let previous = metrics_global.get_metrics()
  let assert Ok(metrics) = metrics_actor.start()
  use <- exception.defer(fn() {
    case previous {
      Some(previous) -> metrics_global.set_metrics(previous)
      option.None -> metrics_global.clear_metrics()
    }
  })
  metrics_global.set_metrics(metrics)
  body(metrics)
}

fn await_metric(metrics, fragment: String, tries: Int) -> Bool {
  case string.contains(metrics_actor.get_metrics(metrics), fragment), tries {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(10)
      await_metric(metrics, fragment, tries - 1)
    }
  }
}

pub fn cut_and_cancelled_calls_are_counted_test() {
  use metrics <- with_metrics
  tool_runner.start_in_slot(
    30,
    Some(tool_runner.SlotRequest("web", "slots-g", 1000)),
    fn() {
      process.sleep_forever()
      Ok("unreachable")
    },
  )
  |> tool_runner.await
  |> should.equal(tool_runner.TimedOut(30))
  await_metric(metrics, "tool_timeouts_total{tool=\"web\"} 1", 200)
  |> should.be_true

  let turn =
    process.spawn_unlinked(fn() {
      in_slot("web", "slots-g", 1000, fn() {
        process.sleep_forever()
        Ok("unreachable")
      })
      |> tool_runner.await
    })
  wait_until(fn() { tool_slots.running_for("web", "slots-g") == 1 }, 200)
  await_metric(metrics, "tool_running{tool=\"web\"} 1", 200) |> should.be_true
  process.kill(turn)
  await_metric(metrics, "tool_cancelled_total{tool=\"web\"} 1", 200)
  |> should.be_true
  await_metric(metrics, "tool_running{tool=\"web\"} 0", 200) |> should.be_true
}

pub fn waiting_calls_are_shown_test() {
  use metrics <- with_metrics
  let releases = process.new_subject()
  let held =
    [1, 2]
    |> list.map(fn(_) {
      in_slot("computador", "slots-h", 5000, fn() {
        let release = process.new_subject()
        process.send(releases, release)
        let _ = process.receive(release, 5000)
        Ok("liberado")
      })
    })
  let assert Ok(first) = process.receive(releases, 1000)
  let assert Ok(second) = process.receive(releases, 1000)
  let waiting = in_slot("computador", "slots-h", 5000, fn() { Ok("depois") })
  await_metric(metrics, "tool_waiting{tool=\"computador\"} 1", 200)
  |> should.be_true
  process.send(first, Nil)
  tool_runner.await(waiting) |> should.equal(tool_runner.Done(Ok("depois")))
  process.send(second, Nil)
  list.each(held, tool_runner.await)
  await_metric(metrics, "tool_waiting{tool=\"computador\"} 0", 200)
  |> should.be_true
}

/// A full instance stays at its limit while others keep trying: a refused
/// try never shows as a ninth call, not even for an instant.
pub fn a_refused_try_never_shows_above_the_limit_test() {
  let held =
    list.repeat(Nil, 8)
    |> list.index_map(fn(_, i) {
      let assert Ok(slot) =
        tool_slots.try_take("computador", "cheio-" <> int.to_string(i))
      slot
    })
  let done = process.new_subject()
  list.repeat(Nil, 16)
  |> list.index_map(fn(_, i) {
    process.spawn(fn() {
      list.repeat(Nil, 3000)
      |> list.each(fn(_) {
        let _ = tool_slots.try_take("computador", "tenta-" <> int.to_string(i))
        Nil
      })
      process.send(done, Nil)
    })
  })
  |> list.length
  |> should.equal(16)
  let highest = sample_until_done(done, 16, 0)
  list.each(held, tool_slots.give_back)
  highest |> should.equal(8)
  tool_slots.running("computador") |> should.equal(0)
}

fn sample_until_done(done, left: Int, highest: Int) -> Int {
  case left {
    0 -> highest
    _ -> {
      let highest = int.max(highest, tool_slots.running("computador"))
      case process.receive(done, 0) {
        Ok(Nil) -> sample_until_done(done, left - 1, highest)
        Error(Nil) -> sample_until_done(done, left, highest)
      }
    }
  }
}
