import exception
import gleam/list
import gleam/string
import gleeunit/should
import supernova/agenda/store
import test_workspace

// 2026-11-21 12:00 in São Paulo (a Saturday).
const now = 1_795_273_200_000

const hour = 3_600_000

const sp = -180

const owner = "telegram:924255495"

fn with_data_dir(body: fn(String) -> a) -> a {
  let dir = test_workspace.create_temp_dir("agenda-store")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  body(dir)
}

pub fn add_and_list_test() {
  use dir <- with_data_dir
  let assert Ok(entry) =
    store.add(dir, owner, "0 5 * * *", "Monte o radar de IA", now, sp)
  entry.id |> should.equal(1)
  entry.next_run_at |> should.equal(now + 17 * hour)
  let assert [listed] = store.list(dir, owner)
  listed.request |> should.equal("Monte o radar de IA")
  listed.spec |> should.equal("0 5 * * *")
}

pub fn ids_keep_growing_after_removal_test() {
  use dir <- with_data_dir
  let assert Ok(_) = store.add(dir, owner, "0 5 * * *", "a", now, sp)
  let assert Ok(_) = store.remove(dir, owner, 1)
  let assert Ok(second) = store.add(dir, owner, "0 6 * * *", "b", now, sp)
  second.id |> should.equal(2)
}

pub fn agendas_are_per_person_test() {
  use dir <- with_data_dir
  let assert Ok(_) = store.add(dir, owner, "0 5 * * *", "a", now, sp)
  store.list(dir, "telegram:1") |> should.equal([])
  store.remove(dir, "telegram:1", 1) |> should.be_error
}

pub fn limit_per_person_test() {
  use dir <- with_data_dir
  list.repeat(Nil, store.max_entries)
  |> list.each(fn(_) {
    let assert Ok(_) = store.add(dir, owner, "0 5 * * *", "x", now, sp)
    Nil
  })
  store.add(dir, owner, "0 5 * * *", "x", now, sp) |> should.be_error
}

pub fn empty_or_long_request_is_refused_test() {
  use dir <- with_data_dir
  store.add(dir, owner, "0 5 * * *", "   ", now, sp) |> should.be_error
  let long = string.repeat("a", store.max_request_length + 1)
  store.add(dir, owner, "0 5 * * *", long, now, sp) |> should.be_error
}

pub fn bad_schedule_is_refused_test() {
  use dir <- with_data_dir
  store.add(dir, owner, "* * * * *", "x", now, sp) |> should.be_error
  store.list(dir, owner) |> should.equal([])
}

pub fn take_due_advances_before_returning_test() {
  use dir <- with_data_dir
  let assert Ok(entry) = store.add(dir, owner, "0 5 * * *", "radar", now, sp)
  // Nothing is due before the time.
  store.take_due(dir, owner, entry.next_run_at - 1, sp) |> should.equal([])
  let assert [due] = store.take_due(dir, owner, entry.next_run_at + 1000, sp)
  due.request |> should.equal("radar")
  // Already advanced to the next day: a second tick does not fire again.
  store.take_due(dir, owner, entry.next_run_at + 2000, sp) |> should.equal([])
  let assert [after] = store.list(dir, owner)
  after.next_run_at |> should.equal(entry.next_run_at + 24 * hour)
}

pub fn once_is_removed_after_firing_test() {
  use dir <- with_data_dir
  let assert Ok(entry) =
    store.add(dir, owner, "2026-11-21 13:00", "lembrar", now, sp)
  let assert [_] = store.take_due(dir, owner, entry.next_run_at, sp)
  store.list(dir, owner) |> should.equal([])
}

pub fn missed_beyond_grace_is_skipped_test() {
  use dir <- with_data_dir
  let assert Ok(entry) = store.add(dir, owner, "0 5 * * *", "radar", now, sp)
  // The service was down for three hours past 05:00: skip, do not fire late.
  store.take_due(dir, owner, entry.next_run_at + 3 * hour, sp)
  |> should.equal([])
  let assert [after] = store.list(dir, owner)
  after.next_run_at |> should.equal(entry.next_run_at + 24 * hour)
}

pub fn missed_once_beyond_grace_is_dropped_test() {
  use dir <- with_data_dir
  let assert Ok(entry) =
    store.add(dir, owner, "2026-11-21 13:00", "lembrar", now, sp)
  store.take_due(dir, owner, entry.next_run_at + 3 * hour, sp)
  |> should.equal([])
  store.list(dir, owner) |> should.equal([])
}

pub fn clear_removes_everything_test() {
  use dir <- with_data_dir
  let assert Ok(_) = store.add(dir, owner, "0 5 * * *", "a", now, sp)
  let assert Ok(_) = store.add(dir, owner, "0 6 * * *", "b", now, sp)
  store.clear(dir, owner) |> should.equal(Ok(2))
  store.list(dir, owner) |> should.equal([])
  store.clear(dir, owner) |> should.equal(Ok(0))
}

pub fn owners_lists_people_with_entries_test() {
  use dir <- with_data_dir
  let assert Ok(_) = store.add(dir, owner, "0 5 * * *", "a", now, sp)
  store.owners(dir) |> should.equal([owner])
}
