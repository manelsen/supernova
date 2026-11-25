//// Every tool call runs under a guard of its own (PRD-F, F-02).
////
//// ```
//// turn ──start──► guard ──link──► worker (runs the tool)
////   ▲               │ monitors the turn
////   └───outcome─────┘ enforces the time limit
//// ```
////
//// - **Time limit (I1).** When it passes, the guard stops the worker with the
////   exit reason `timeout` and answers `TimedOut`.
//// - **Nothing alive without an owner (I2).** The guard monitors the turn
////   that started it. If the turn dies, the guard stops the worker with the
////   reason `cancelled` and goes away; nobody is waiting for an answer. If
////   the guard itself dies, the link takes the worker with it.
//// - **The exit reasons are part of the contract:** the gateway watches the
////   worker and audits a call cut short with the reason it was cut
////   (`syscall/actor.invoke_tool`), so every call is reported once (I3).
////
//// A guard is one process per call, not a central supervisor per tool:
//// nothing is shared between calls, so a stuck tool cannot slow another
//// one down (I5). Counting slots per tool and per agent (F-03) happens in
//// ETS, outside any process.

import gleam/dynamic/decode
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/core/exception_guard
import supernova/core/tool_slots

/// How a call ended.
pub type Outcome {
  /// The tool answered (or failed on its own) in time.
  Done(Result(String, String))
  /// The time limit passed; the worker was stopped.
  TimedOut(limit_ms: Int)
}

/// Exit reason given to a worker cut at its time limit.
pub const timeout_reason = "timeout"

/// Exit reason given to a worker whose turn died.
pub const cancelled_reason = "cancelled"

/// A call that was started and is not awaited yet.
pub opaque type Pending {
  Pending(reply: Subject(Outcome), guard: Monitor, limit_ms: Int)
}

type GuardEvent {
  Finished(Result(String, String))
  LimitPassed
  OwnerDown
  WorkerExited(process.ExitMessage)
}

/// Start `work` under a guard owned by the calling process. The call starts
/// at once; `await` collects its outcome.
pub fn start(limit_ms: Int, work: fn() -> Result(String, String)) -> Pending {
  start_in_slot(limit_ms, None, work)
}

/// Which slot a call needs (F-03): its tool, its agent, and how long it may
/// wait for one.
pub type SlotRequest {
  SlotRequest(tool: String, agent: String, wait_ms: Int)
}

/// Like `start`, first taking a slot of the tool for the agent. Without one
/// within `wait_ms`, the call answers that the tool is busy and runs
/// nothing. The time limit starts once the slot is taken.
pub fn start_in_slot(
  limit_ms: Int,
  slot: Option(SlotRequest),
  work: fn() -> Result(String, String),
) -> Pending {
  let owner = process.self()
  let reply = process.new_subject()
  // The guard monitors the turn before it waits or starts the worker: a
  // turn that is already gone is seen at once.
  let guard =
    process.spawn_unlinked(fn() {
      run_guard(owner, reply, limit_ms, slot, work)
    })
  Pending(reply: reply, guard: process.monitor(guard), limit_ms: limit_ms)
}

/// The outcome of a started call. Only the process that started it may
/// await it.
pub fn await(pending: Pending) -> Outcome {
  let outcome =
    process.new_selector()
    |> process.select(pending.reply)
    |> process.select_specific_monitor(pending.guard, fn(down) {
      Done(Error("tool stopped: " <> string.inspect(down.reason)))
    })
    |> process.selector_receive_forever
  process.demonitor_process(pending.guard)
  outcome
}

/// Start and await one call.
pub fn run(limit_ms: Int, work: fn() -> Result(String, String)) -> Outcome {
  start(limit_ms, work) |> await
}

/// The reason a worker was stopped with, when it was one of ours.
pub fn stop_reason(reason: process.ExitReason) -> Result(String, Nil) {
  case reason {
    process.Abnormal(dynamic_reason) ->
      case decode.run(dynamic_reason, decode.string) {
        Ok(text) if text == timeout_reason || text == cancelled_reason ->
          Ok(text)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn run_guard(
  owner: Pid,
  reply: Subject(Outcome),
  limit_ms: Int,
  slot: Option(SlotRequest),
  work: fn() -> Result(String, String),
) -> Nil {
  process.trap_exits(True)
  let owner_monitor = process.monitor(owner)
  let owner_down =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(_) { Nil })
  case slot {
    None -> guard_call(owner_monitor, reply, limit_ms, work)
    Some(request) ->
      case wait_for_slot(owner_down, request, now() + request.wait_ms) {
        // The turn died while waiting: nothing to run, nobody to answer.
        SlotOwnerGone -> Nil
        SlotBusy -> process.send(reply, Done(Error(tool_slots.busy_message)))
        SlotTaken(taken) -> {
          guard_call(owner_monitor, reply, limit_ms, work)
          tool_slots.give_back(taken)
        }
      }
  }
}

type SlotWait {
  SlotTaken(tool_slots.Slot)
  SlotBusy
  SlotOwnerGone
}

/// Try for a slot until `deadline`, looking at the turn between tries.
fn wait_for_slot(
  owner_down: process.Selector(Nil),
  request: SlotRequest,
  deadline: Int,
) -> SlotWait {
  case tool_slots.try_take(request.tool, request.agent) {
    Ok(taken) -> SlotTaken(taken)
    Error(Nil) -> {
      let left = deadline - now()
      case left <= 0 {
        True -> SlotBusy
        False ->
          case process.selector_receive(owner_down, int.min(left, 20)) {
            Ok(Nil) -> SlotOwnerGone
            Error(Nil) -> wait_for_slot(owner_down, request, deadline)
          }
      }
    }
  }
}

fn guard_call(
  owner_monitor: Monitor,
  reply: Subject(Outcome),
  limit_ms: Int,
  work: fn() -> Result(String, String),
) -> Nil {
  let result = process.new_subject()
  let limit = process.new_subject()
  // Linked: if the guard dies, the worker dies with it.
  let worker =
    process.spawn(fn() {
      case exception_guard.run(fn() { process.send(result, work()) }) {
        Ok(Nil) -> Nil
        Error(reason) -> process.send(result, Error("tool crashed: " <> reason))
      }
    })
  let timer = process.send_after(limit, limit_ms, Nil)
  let events =
    process.new_selector()
    |> process.select_map(result, Finished)
    |> process.select_map(limit, fn(_) { LimitPassed })
    |> process.select_specific_monitor(owner_monitor, fn(_) { OwnerDown })
    |> process.select_trapped_exits(WorkerExited)
  guard_loop(events, worker, reply, limit_ms)
  let _ = process.cancel_timer(timer)
  Nil
}

fn guard_loop(
  events: process.Selector(GuardEvent),
  worker: Pid,
  reply: Subject(Outcome),
  limit_ms: Int,
) -> Nil {
  case process.selector_receive_forever(events) {
    Finished(result) -> process.send(reply, Done(result))
    LimitPassed -> {
      process.send_abnormal_exit(worker, timeout_reason)
      process.send(reply, TimedOut(limit_ms))
    }
    OwnerDown -> process.send_abnormal_exit(worker, cancelled_reason)
    WorkerExited(exit) ->
      case exit.pid == worker, exit.reason {
        // A worker that finished normally already sent its result.
        True, process.Normal -> guard_loop(events, worker, reply, limit_ms)
        True, reason ->
          process.send(reply, Done(Error("tool stopped: " <> describe(reason))))
        False, _ -> guard_loop(events, worker, reply, limit_ms)
      }
  }
}

fn describe(reason: process.ExitReason) -> String {
  case reason {
    process.Normal -> "normal"
    process.Killed -> "killed"
    process.Abnormal(term) -> string.inspect(term)
  }
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now() -> Int
