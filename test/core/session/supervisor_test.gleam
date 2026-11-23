//// Tests for the Session Supervisor module.
////
//// Verifies session lifecycle management: start, stop, list, and error cases.

import exception
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleeunit/should
import supernova/core/session/history_store
import supernova/core/session/server
import supernova/core/session/supervisor
import test_workspace

pub fn start_and_list_sessions_test() {
  let assert Ok(sup) = supervisor.start()

  // Initially no sessions
  let sessions = supervisor.list_sessions(sup)
  sessions
  |> should.equal([])

  // Start a session
  let assert Ok(_pid) = supervisor.start_session(sup, "session_001")

  // Now one session exists
  let sessions = supervisor.list_sessions(sup)
  sessions
  |> should.equal(["session_001"])
}

pub fn start_multiple_sessions_test() {
  let assert Ok(sup) = supervisor.start()

  let assert Ok(_) = supervisor.start_session(sup, "s1")
  let assert Ok(_) = supervisor.start_session(sup, "s2")
  let assert Ok(_) = supervisor.start_session(sup, "s3")

  let sessions = supervisor.list_sessions(sup)
  sessions
  |> list.length
  |> should.equal(3)
}

pub fn stop_session_test() {
  let assert Ok(sup) = supervisor.start()

  let assert Ok(_) = supervisor.start_session(sup, "to_stop")
  let assert Ok(_) = supervisor.start_session(sup, "to_keep")

  // Stop one session
  let assert Ok(Nil) = supervisor.stop_session(sup, "to_stop")

  let sessions = supervisor.list_sessions(sup)
  sessions
  |> should.equal(["to_keep"])
}

pub fn stop_nonexistent_session_test() {
  let assert Ok(sup) = supervisor.start()

  let result = supervisor.stop_session(sup, "does_not_exist")
  result
  |> should.be_error
}

pub fn duplicate_session_id_test() {
  let assert Ok(sup) = supervisor.start()

  let assert Ok(_) = supervisor.start_session(sup, "dup")

  // Starting with same ID should return error
  let result = supervisor.start_session(sup, "dup")
  result
  |> should.be_error
}

pub fn session_lookup_by_id_test() {
  let assert Ok(sup) = supervisor.start()

  let assert Ok(_) = supervisor.start_session(sup, "lookup_test")

  // Should be able to find session by ID
  let result = supervisor.get_session(sup, "lookup_test")
  result
  |> should.be_ok
}

pub fn started_session_is_rich_session_test() {
  let assert Ok(sup) = supervisor.start()
  let assert Ok(session) = supervisor.start_session(sup, "rich_session")

  let assert Ok(Nil) = server.set_model(session, "gpt-4")
  server.get_model(session)
  |> should.equal(Some("gpt-4"))
}

pub fn session_not_found_lookup_test() {
  let assert Ok(sup) = supervisor.start()

  let result = supervisor.get_session(sup, "ghost")
  result
  |> should.be_error
}

/// A session that dies (here, killed mid-life) leaves the registry; the
/// supervisor survives, and the next start brings the conversation back
/// from disk. Before, the dead session's link took the supervisor, and with
/// it the whole runtime, down.
pub fn a_dead_session_does_not_take_the_supervisor_down_test() {
  let dir = test_workspace.create_temp_dir("session_supervisor_kill")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  let store = history_store.HistoryStore(data_dir: dir, limit: 40)
  let assert Ok(sup) = supervisor.start_with_history(store)
  let assert Ok(session) = supervisor.start_session(sup, "sim:dm:u1")
  let assert Ok(Nil) =
    server.append_messages(session, [
      server.ChatMessage(role: "user", content: "oi"),
      server.ChatMessage(role: "assistant", content: "olá"),
    ])
  let assert Ok(_) = supervisor.start_session(sup, "sim:dm:u2")

  let assert Ok(pid) = process.subject_owner(session)
  process.kill(pid)
  wait_until(fn() { !list.contains(supervisor.list_sessions(sup), "sim:dm:u1") })

  supervisor.list_sessions(sup) |> should.equal(["sim:dm:u2"])
  let assert Ok(again) = supervisor.start_session(sup, "sim:dm:u1")
  server.get_history(again)
  |> list.map(fn(message) { message.content })
  |> should.equal(["oi", "olá"])
  supervisor.stop(sup)
}

/// Polls `ready` (the supervisor handles the exit on its own schedule), up
/// to two seconds.
fn wait_until(ready: fn() -> Bool) -> Nil {
  wait_loop(ready, 100)
}

fn wait_loop(ready: fn() -> Bool, tries: Int) -> Nil {
  case ready(), tries {
    True, _ -> Nil
    False, 0 -> panic as "condition not reached"
    False, _ -> {
      process.sleep(20)
      wait_loop(ready, tries - 1)
    }
  }
}
