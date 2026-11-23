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
  int.range(from: 1, to: 1101, with: Nil, run: fn(_, n) {
    let message = msg(string.inspect(n), "texto " <> string.inspect(n))
    let _ = inbox.receive(box, message, n)
    inbox.done(box, inbox.key(message), n)
  })
  let _ = inbox.receive(box, msg("pending", "ainda esperando"), 2000)
  inbox.count(box) |> should.equal(#(1, 1101))

  let assert Ok(text) = read_file(dir <> "/inbox.jsonl")
  let lines = string.split(text, "\n") |> list.filter(fn(l) { l != "" })
  { list.length(lines) < 2000 } |> should.equal(True)
  string.contains(text, "texto 1\"") |> should.equal(False)
  string.contains(text, "ainda esperando") |> should.equal(True)

  let assert Ok(after) = inbox.start(dir)
  inbox.receive(after, msg("5", "texto 5"), 3000) |> should.equal(False)
  let assert [entry] = inbox.recover(after, 3000)
  entry.message.content |> should.equal("ainda esperando")
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
  process.receive(calls, 200) |> should.equal(Error(Nil))
  await_pending(box, 0, 50) |> should.equal(0)
}

fn await_pending(box: inbox.Inbox, expected: Int, attempts: Int) -> Int {
  let #(pending, _) = inbox.count(box)
  case pending == expected || attempts == 0 {
    True -> pending
    False -> {
      process.sleep(20)
      await_pending(box, expected, attempts - 1)
    }
  }
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
  supernova.replay_inbox(registry, handler)

  let assert Ok(port.InboundMessage(replayed)) = process.receive(calls, 2000)
  replayed.content |> should.equal("esperando")
  process.receive(calls, 200) |> should.equal(Error(Nil))
  await_pending(box, 0, 50) |> should.equal(0)
}

fn now() -> Int {
  channel_kit.current_timestamp()
}

/// SIGTERM (what `docker stop` sends) wakes the main process instead of
/// killing the VM, so Supernova's own shutdown runs.
pub fn sigterm_wakes_the_waiting_process_test() {
  use <- exception.defer(restore_default)
  let result = process.new_subject()
  process.spawn(fn() { process.send(result, wait_for_shutdown(5000)) })
  await_installed(50)
  notify_sigterm()
  process.receive(result, 2000) |> should.equal(Ok(atom("sigterm")))
}

fn await_installed(attempts: Int) -> Nil {
  case installed() || attempts == 0 {
    True -> Nil
    False -> {
      process.sleep(10)
      await_installed(attempts - 1)
    }
  }
}

@external(erlang, "inbox_test_ffi", "installed")
fn installed() -> Bool

@external(erlang, "erlang", "binary_to_atom")
fn atom(name: String) -> Atom

type Atom

@external(erlang, "supernova_signal_ffi", "wait_for_shutdown")
fn wait_for_shutdown(timeout: Int) -> Atom

@external(erlang, "supernova_signal_ffi", "notify_sigterm")
fn notify_sigterm() -> Nil

@external(erlang, "supernova_signal_ffi", "restore_default")
fn restore_default() -> Nil

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "append_file")
fn append_file(path: String, content: String) -> Result(Nil, String)
