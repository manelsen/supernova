import exception
import gleam/string
import gleeunit/should
import supernova/agenda/store
import supernova/tools/agenda
import test_workspace

// 2026-11-21 12:00 in São Paulo (a Saturday).
const now = 1_795_273_200_000

const sp = -180

const owner = "telegram:924255495"

fn with_data_dir(body: fn(String) -> a) -> a {
  let dir = test_workspace.create_temp_dir("agenda-tool")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  body(dir)
}

fn run(dir: String, principal: String, args: String) -> Result(String, String) {
  agenda.execute_for(dir, principal, now, sp, args)
}

pub fn add_reports_next_run_test() {
  use dir <- with_data_dir
  let assert Ok(reply) =
    run(
      dir,
      owner,
      "{\"action\":\"add\",\"when\":\"0 5 * * *\",\"request\":\"Radar de IA\"}",
    )
  string.contains(reply, "1") |> should.be_true
  string.contains(reply, "22/11/2026 05:00") |> should.be_true
  let assert [_] = store.list(dir, owner)
}

pub fn list_shows_entries_test() {
  use dir <- with_data_dir
  let assert Ok(_) =
    run(
      dir,
      owner,
      "{\"action\":\"add\",\"when\":\"0 5 * * *\",\"request\":\"Radar de IA\"}",
    )
  let assert Ok(reply) = run(dir, owner, "{\"action\":\"list\"}")
  string.contains(reply, "Radar de IA") |> should.be_true
  string.contains(reply, "0 5 * * *") |> should.be_true
}

pub fn empty_list_says_so_test() {
  use dir <- with_data_dir
  run(dir, owner, "{\"action\":\"list\"}")
  |> should.equal(Ok("(agenda vazia)"))
}

pub fn remove_by_id_test() {
  use dir <- with_data_dir
  let assert Ok(_) =
    run(
      dir,
      owner,
      "{\"action\":\"add\",\"when\":\"0 5 * * *\",\"request\":\"Radar\"}",
    )
  let assert Ok(_) = run(dir, owner, "{\"action\":\"remove\",\"id\":1}")
  store.list(dir, owner) |> should.equal([])
  run(dir, owner, "{\"action\":\"remove\",\"id\":1}") |> should.be_error
}

pub fn uppercase_action_test() {
  use dir <- with_data_dir
  run(dir, owner, "{\"action\":\" LIST \"}") |> should.be_ok
}

pub fn schedule_error_is_explained_test() {
  use dir <- with_data_dir
  let assert Error(reason) =
    run(
      dir,
      owner,
      "{\"action\":\"add\",\"when\":\"*/5 * * * *\",\"request\":\"x\"}",
    )
  string.contains(reason, "uma vez por hora") |> should.be_true
}

pub fn missing_fields_are_refused_test() {
  use dir <- with_data_dir
  run(dir, owner, "{\"action\":\"add\",\"when\":\"0 5 * * *\"}")
  |> should.be_error
  run(dir, owner, "{\"action\":\"remove\"}") |> should.be_error
  run(dir, owner, "{\"action\":\"fly\"}") |> should.be_error
  run(dir, owner, "not json") |> should.be_error
}

pub fn channels_without_private_delivery_are_refused_test() {
  use dir <- with_data_dir
  run(
    dir,
    "discord:42",
    "{\"action\":\"add\",\"when\":\"0 5 * * *\",\"request\":\"x\"}",
  )
  |> should.be_error
}
