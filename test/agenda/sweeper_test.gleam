import exception
import gleam/erlang/process
import gleam/string
import gleeunit/should
import supernova/agenda/store
import supernova/agenda/sweeper
import supernova/self/epoch
import test_workspace

// 2026-11-21 12:00 in São Paulo (a Saturday).
const now = 1_795_273_200_000

const sp = -180

const owner = "telegram:924255495"

fn with_data_dir(body: fn(String) -> a) -> a {
  let dir = test_workspace.create_temp_dir("agenda-sweeper")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  body(dir)
}

pub fn due_entry_becomes_a_private_message_test() {
  use dir <- with_data_dir
  let assert Ok(entry) =
    store.add(dir, owner, "0 5 * * *", "Monte o radar de IA", now, sp)
  let inbox = process.new_subject()
  sweeper.sweep(dir, sp, entry.next_run_at, process.send(inbox, _))
  |> should.equal(1)
  let assert Ok(message) = process.receive(inbox, 100)
  message.channel |> should.equal("telegram")
  message.channel_id |> should.equal("924255495")
  message.user_id |> should.equal("924255495")
  message.is_bot |> should.be_false
  string.contains(message.content, "Monte o radar de IA") |> should.be_true
  // Never read as a command.
  string.starts_with(message.content, "/") |> should.be_false
}

pub fn nothing_due_sends_nothing_test() {
  use dir <- with_data_dir
  let assert Ok(entry) = store.add(dir, owner, "0 5 * * *", "radar", now, sp)
  let inbox = process.new_subject()
  sweeper.sweep(dir, sp, entry.next_run_at - 1, process.send(inbox, _))
  |> should.equal(0)
  process.receive(inbox, 10) |> should.be_error
}

pub fn a_tick_runs_an_entry_once_test() {
  use dir <- with_data_dir
  let assert Ok(entry) = store.add(dir, owner, "0 5 * * *", "radar", now, sp)
  let inbox = process.new_subject()
  sweeper.sweep(dir, sp, entry.next_run_at, process.send(inbox, _))
  |> should.equal(1)
  sweeper.sweep(dir, sp, entry.next_run_at + 30_000, process.send(inbox, _))
  |> should.equal(0)
}

// /esquecer between taking an entry and handing it over: the rest is
// dropped, never run after the person asked to forget.
pub fn forget_during_a_sweep_drops_the_rest_test() {
  use dir <- with_data_dir
  let assert Ok(first) = store.add(dir, owner, "0 5 * * *", "um", now, sp)
  let assert Ok(_) = store.add(dir, owner, "0 5 * * *", "dois", now, sp)
  let inbox = process.new_subject()
  sweeper.sweep(dir, sp, first.next_run_at, fn(message) {
    let _ = epoch.bump(dir, owner)
    process.send(inbox, message)
  })
  |> should.equal(1)
  let assert Ok(_) = process.receive(inbox, 100)
  process.receive(inbox, 10) |> should.be_error
}
