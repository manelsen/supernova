//// The durable inbox keeps what arrived until its turn ends, answers a
//// message delivered twice once, gives back after a restart what was
//// waiting, and Supernova stops on SIGTERM through its own shutdown.

import exception
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova
import supernova/channel/channel_kit
import supernova/channel/chat_lanes
import supernova/channel/health as channel_health
import supernova/channel/inbox
import supernova/channel/port
import supernova/channel/registry
import test_workspace

const hour = 3_600_000

fn with_dir(body: fn(String) -> a) -> a {
  let dir = test_workspace.create_temp_dir("inbox")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  body(dir)
}

fn msg(id: String, content: String) -> port.ChannelMessage {
  port.ChannelMessage(
    id: id,
    channel: "telegram",
    channel_id: "42",
    user_id: "7",
    username: "ana",
    content: content,
    is_bot: False,
    reply_to_id: Some("3"),
  )
}

pub fn a_message_delivered_twice_is_admitted_once_test() {
  use dir <- with_dir
  let assert Ok(box) = inbox.start(dir)
  inbox.receive(box, msg("1", "oi"), 1000) |> should.equal(True)
  inbox.receive(box, msg("1", "oi"), 1001) |> should.equal(False)
  // The same id in another chat is another message.
  inbox.receive(box, port.ChannelMessage(..msg("1", "oi"), channel_id: "43"), 1)
  |> should.equal(True)
  inbox.count(box) |> should.equal(#(2, 2))
}

pub fn what_was_waiting_comes_back_after_a_restart_test() {
  use dir <- with_dir
  let assert Ok(box) = inbox.start(dir)
  let _ = inbox.receive(box, msg("1", "primeira"), 1000)
  let _ = inbox.receive(box, msg("2", "segunda"), 2000)
  inbox.done(box, inbox.key(msg("1", "primeira")), 3000)
  // A call orders the done before the restart.
  inbox.count(box) |> should.equal(#(1, 2))

  let assert Ok(after) = inbox.start(dir)
  let assert [entry] = inbox.recover(after, 4000)
  entry.message |> should.equal(msg("2", "segunda"))
  entry.attempts |> should.equal(1)
  // Telegram delivering the last batch again is recognised, answered or not.
  inbox.receive(after, msg("1", "primeira"), 5000) |> should.equal(False)
  inbox.receive(after, msg("2", "segunda"), 5000) |> should.equal(False)
}

pub fn a_message_is_tried_again_only_once_test() {
  use dir <- with_dir
  let assert Ok(box) = inbox.start(dir)
  let _ = inbox.receive(box, msg("1", "trava tudo"), 1000)
  let assert Ok(second) = inbox.start(dir)
  let assert [_] = inbox.recover(second, 2000)
  // The retry did not finish either: the next boot drops it.
  let assert Ok(third) = inbox.start(dir)
  inbox.recover(third, 3000) |> should.equal([])
  let assert Ok(fourth) = inbox.start(dir)
  inbox.count(fourth) |> should.equal(#(0, 1))
}

pub fn a_message_older_than_a_day_is_not_answered_test() {
  use dir <- with_dir
  let assert Ok(box) = inbox.start(dir)
  let _ = inbox.receive(box, msg("1", "antiga"), 1000)
  let _ = inbox.receive(box, msg("2", "recente"), 20 * hour)
  let assert Ok(after) = inbox.start(dir)
  inbox.recover(after, 25 * hour)
  |> list.map(fn(entry) { entry.message.id })
  |> should.equal(["2"])
}

pub fn the_log_is_compacted_and_forgets_finished_text_test() {
  use dir <- with_dir
  let assert Ok(box) = inbox.start(dir)
  // Each message is two lines; the log compacts when it holds 2000 more
  // lines than keys to remember, around the 2000th message.
  int.range(from: 1, to: 2201, with: Nil, run: fn(_, n) {
    let message = msg(string.inspect(n), "texto " <> string.inspect(n))
    let _ = inbox.receive(box, message, n)
    inbox.done(box, inbox.key(message), n)
  })
  let _ = inbox.receive(box, msg("pending", "ainda esperando"), 3000)
  inbox.count(box) |> should.equal(#(1, 2201))

  let assert Ok(text) = read_file(dir <> "/inbox.jsonl")
  let lines = string.split(text, "\n") |> list.filter(fn(l) { l != "" })
  { list.length(lines) < 2 * 2201 } |> should.equal(True)
  string.contains(text, "texto 1\"") |> should.equal(False)
  string.contains(text, "ainda esperando") |> should.equal(True)

  let assert Ok(after) = inbox.start(dir)
  inbox.receive(after, msg("5", "texto 5"), 4000) |> should.equal(False)
  let assert [entry] = inbox.recover(after, 4000)
  entry.message.content |> should.equal("ainda esperando")
}

/// An inbox that does not answer must not take the channel down: the
/// message still reaches its lane.
/// Messages that reach the inbox together go to disk in one append, and
/// every one of them is there after a restart (PRD-P, P-06).
pub fn messages_arriving_together_are_written_together_test() {
  use dir <- with_dir
  let assert Ok(box) = inbox.start(dir)
  let assert Ok(pid) = process.subject_owner(box)
  // Hold the inbox while a hundred messages arrive, then let it go.
  sys_suspend(pid)
  let answers = process.new_subject()
  list.each(int.range(1, 101, [], list.prepend), fn(i) {
    process.spawn(fn() {
      process.send(
        answers,
        inbox.receive(box, msg(int.to_string(i), "oi"), 1000 + i),
      )
    })
  })
  queued_within(pid, 100, 5000) |> should.be_true()
  sys_resume(pid)
  list.each(int.range(1, 101, [], list.prepend), fn(_) {
    process.receive(answers, within: 5000) |> should.equal(Ok(True))
  })
  { inbox.writes(box) < 10 } |> should.be_true()
  inbox.stop(box)

  let assert Ok(again) = inbox.start(dir)
  inbox.recover(again, 2000) |> list.length |> should.equal(100)
  inbox.stop(again)
}

fn queued_within(pid: process.Pid, n: Int, ms: Int) -> Bool {
  case message_queue_len(pid) >= n, ms <= 0 {
    True, _ -> True
    False, True -> False
    False, False -> {
      process.sleep(10)
      queued_within(pid, n, ms - 10)
    }
  }
}

@external(erlang, "sys", "suspend")
fn sys_suspend(pid: process.Pid) -> Nil

@external(erlang, "sys", "resume")
fn sys_resume(pid: process.Pid) -> Nil

@external(erlang, "inbox_test_ffi", "message_queue_len")
fn message_queue_len(pid: process.Pid) -> Int

pub fn a_stuck_inbox_does_not_stop_the_channel_test() {
  let previous = inbox.global()
  use <- exception.defer(fn() {
    case previous {
      Some(previous) -> inbox.set_global(previous)
      None -> inbox.clear_global()
    }
  })
  let ready = process.new_subject()
  process.spawn(fn() {
    process.send(ready, process.new_subject())
    process.sleep_forever()
  })
  let assert Ok(stuck) = process.receive(ready, 1000)
  inbox.set_global(stuck)

  let calls = process.new_subject()
  let handler = fn(inbound, _events) {
    process.send(calls, inbound)
    Error(port.Ignored("test"))
  }
  channel_kit.dispatch_inbound(
    handler,
    fn(_) { Ok(Nil) },
    fn(_, _) { Ok(Nil) },
    port.InboundMessage(msg("stuck", "oi")),
    "registry:inbox-stuck",
    1000,
  )
  let assert Ok(_) = process.receive(calls, 2000)
}

pub fn a_damaged_line_is_skipped_test() {
  use dir <- with_dir
  let assert Ok(box) = inbox.start(dir)
  let _ = inbox.receive(box, msg("1", "oi"), 1000)
  inbox.count(box) |> should.equal(#(1, 1))
  let assert Ok(Nil) = append_file(dir <> "/inbox.jsonl", "{\"ev\": \"in\",\n")
  let assert Ok(after) = inbox.start(dir)
  inbox.count(after) |> should.equal(#(1, 1))
}

/// Through the channel path: a duplicate never reaches the handler, and a
/// finished turn leaves the inbox.
pub fn dispatch_answers_a_duplicate_once_and_clears_the_inbox_test() {
  use dir <- with_dir
  let assert Ok(box) = inbox.start(dir)
  let previous = inbox.global()
  use <- exception.defer(fn() {
    case previous {
      Some(previous) -> inbox.set_global(previous)
      None -> inbox.clear_global()
    }
  })
  inbox.set_global(box)

  let calls = process.new_subject()
  let handler = fn(inbound, _events) {
    process.send(calls, inbound)
    Error(port.Ignored("test"))
  }
  let message = port.InboundMessage(msg("9", "oi"))
  let dispatch = fn() {
    channel_kit.dispatch_inbound(
      handler,
      fn(_) { Ok(Nil) },
      fn(_, _) { Ok(Nil) },
      message,
      "registry:inbox-test",
      1000,
    )
  }
  dispatch()
  dispatch()
  let assert Ok(_) = process.receive(calls, 2000)
  // The turn has ended when its lane drains; then the inbox is clean.
  settle("registry:inbox-test")
  process.receive(calls, 0) |> should.equal(Error(Nil))
  inbox.count(box).0 |> should.equal(0)
}

/// Wait for every lane of `prefix` to finish, then reopen it.
fn settle(prefix: String) -> Nil {
  chat_lanes.drain(prefix, 2000) |> should.equal(0)
  chat_lanes.undrain(prefix)
}

/// At boot, what was waiting goes back through its channel, as a normal
/// turn, and leaves the inbox when it ends. A message of a channel that is
/// no longer configured is dropped instead of waiting forever.
pub fn boot_answers_what_was_waiting_test() {
  use dir <- with_dir
  let assert Ok(before) = inbox.start(dir)
  let _ = inbox.receive(before, msg("1", "esperando"), now())
  let _ =
    inbox.receive(
      before,
      port.ChannelMessage(..msg("2", "canal sumiu"), channel: "matrix"),
      now(),
    )
  inbox.count(before) |> should.equal(#(2, 2))

  let assert Ok(box) = inbox.start(dir)
  let previous = inbox.global()
  use <- exception.defer(fn() {
    case previous {
      Some(previous) -> inbox.set_global(previous)
      None -> inbox.clear_global()
    }
  })
  inbox.set_global(box)

  let calls = process.new_subject()
  let handler = fn(inbound, _events) {
    process.send(calls, inbound)
    Error(port.Ignored("test"))
  }
  let adapter =
    port.ChannelAdapter(
      name: "telegram",
      send: fn(_) { Ok(Nil) },
      stop_ingress: fn() { Nil },
      stop: fn() { Nil },
    )
  let registry =
    registry.ChannelRegistry(
      id: "registry:inbox-boot",
      channels: dict.from_list([#("telegram", adapter)]),
      streams: dict.new(),
      health: channel_health.start(),
    )
  supernova.replay_inbox(registry, handler, inbox.recover(box, now()))

  let assert Ok(port.InboundMessage(replayed)) = process.receive(calls, 2000)
  replayed.content |> should.equal("esperando")
  settle("registry:inbox-boot")
  process.receive(calls, 0) |> should.equal(Error(Nil))
  inbox.count(box).0 |> should.equal(0)
}

fn now() -> Int {
  channel_kit.current_timestamp()
}

/// SIGTERM (what `docker stop` sends) wakes the main process instead of
/// killing the VM, so Supernova's own shutdown runs.
pub fn sigterm_wakes_the_waiting_process_test() {
  use <- exception.defer(restore_default)
  let installed = process.new_subject()
  let result = process.new_subject()
  process.spawn(fn() {
    let outcome = wait_for_shutdown(5000, fn() { process.send(installed, Nil) })
    process.send(result, outcome)
  })
  let assert Ok(Nil) = process.receive(installed, 2000)
  notify_sigterm()
  process.receive(result, 2000) |> should.equal(Ok(atom("sigterm")))
}

@external(erlang, "erlang", "binary_to_atom")
fn atom(name: String) -> Atom

type Atom

@external(erlang, "supernova_signal_ffi", "wait_for_shutdown")
fn wait_for_shutdown(timeout: Int, installed: fn() -> Nil) -> Atom

@external(erlang, "supernova_signal_ffi", "notify_sigterm")
fn notify_sigterm() -> Nil

@external(erlang, "supernova_signal_ffi", "restore_default")
fn restore_default() -> Nil

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "append_file")
fn append_file(path: String, content: String) -> Result(Nil, String)

// ---------------------------------------------------------------------------
// From the review of the first version
// ---------------------------------------------------------------------------

/// What arrives after the boot took its snapshot is not part of it, and
/// taking the snapshot does not drop it.
pub fn recovery_leaves_live_messages_alone_test() {
  use dir <- with_dir
  let assert Ok(before) = inbox.start(dir)
  let _ = inbox.receive(before, msg("1", "de antes"), now())
  inbox.stop(before)

  let assert Ok(box) = inbox.start(dir)
  let assert [old] = inbox.recover(box, now())
  old.message.id |> should.equal("1")
  let _ = inbox.receive(box, msg("2", "de agora"), now())
  inbox.count(box).0 |> should.equal(2)
}

pub fn messages_of_the_same_millisecond_come_back_in_arrival_order_test() {
  use dir <- with_dir
  let assert Ok(box) = inbox.start(dir)
  let ids = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"]
  list.each(ids, fn(id) {
    let _ = inbox.receive(box, msg(id, "mesma hora"), 1000)
    Nil
  })
  inbox.stop(box)
  let assert Ok(after) = inbox.start(dir)
  inbox.recover(after, 2000)
  |> list.map(fn(entry) { entry.message.id })
  |> should.equal(ids)
}

/// A write cut short must not take the next record down with it.
pub fn a_cut_line_does_not_swallow_the_next_record_test() {
  use dir <- with_dir
  let assert Ok(Nil) =
    append_file(dir <> "/inbox.jsonl", "{\"ev\":\"in\",\"key\":\"tel")
  let assert Ok(box) = inbox.start(dir)
  let _ = inbox.receive(box, msg("1", "depois do corte"), now())
  inbox.stop(box)
  let assert Ok(after) = inbox.start(dir)
  inbox.count(after) |> should.equal(#(1, 1))
}

/// Stop writes what was sent before it: a turn marked done just before the
/// shutdown is not answered again.
pub fn stop_writes_the_last_marks_test() {
  use dir <- with_dir
  let assert Ok(box) = inbox.start(dir)
  let message = msg("1", "oi")
  let _ = inbox.receive(box, message, now())
  inbox.done(box, inbox.key(message), now())
  inbox.stop(box)
  let assert Ok(after) = inbox.start(dir)
  inbox.recover(after, now()) |> should.equal([])
}

/// /esquecer: the person's waiting messages leave the inbox, and the log
/// keeps no text of theirs; another person's waiting message stays.
pub fn forget_erases_the_persons_messages_test() {
  use dir <- with_dir
  let assert Ok(box) = inbox.start(dir)
  let ana_done = msg("1", "SEGREDO respondido")
  let _ = inbox.receive(box, ana_done, now())
  inbox.done(box, inbox.key(ana_done), now())
  let _ = inbox.receive(box, msg("2", "SEGREDO esperando"), now())
  let _ =
    inbox.receive(
      box,
      port.ChannelMessage(..msg("3", "de outra pessoa"), user_id: "8"),
      now(),
    )
  inbox.forget(box, "telegram:7", now()) |> should.equal(1)
  inbox.count(box).0 |> should.equal(1)
  let assert Ok(text) = read_file(dir <> "/inbox.jsonl")
  string.contains(text, "SEGREDO") |> should.equal(False)
  string.contains(text, "de outra pessoa") |> should.equal(True)
  // The keys stay, so a second delivery is still recognised.
  inbox.receive(box, ana_done, now()) |> should.equal(False)
}

/// A message that reaches a lane while Supernova is stopping stays pending,
/// to be answered after the restart.
pub fn a_message_refused_by_a_draining_lane_stays_pending_test() {
  use dir <- with_dir
  let assert Ok(box) = inbox.start(dir)
  let previous = inbox.global()
  use <- exception.defer(fn() {
    chat_lanes.undrain("registry:inbox-drain")
    case previous {
      Some(previous) -> inbox.set_global(previous)
      None -> inbox.clear_global()
    }
  })
  inbox.set_global(box)
  chat_lanes.drain("registry:inbox-drain", 0) |> should.equal(0)
  channel_kit.dispatch_inbound(
    fn(_, _) { Error(port.Ignored("test")) },
    fn(_) { Ok(Nil) },
    fn(_, _) { Ok(Nil) },
    port.InboundMessage(msg("late", "chegou no desligamento")),
    "registry:inbox-drain",
    1000,
  )
  inbox.count(box).0 |> should.equal(1)
}
