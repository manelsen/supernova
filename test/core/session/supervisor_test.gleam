//// Tests for the Session Supervisor module.
////
//// Verifies session lifecycle management: start, stop, list, and error cases.

import gleam/list
import gleeunit/should
import supernova/core/session/supervisor

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

pub fn session_not_found_lookup_test() {
  let assert Ok(sup) = supervisor.start()

  let result = supervisor.get_session(sup, "ghost")
  result
  |> should.be_error
}
