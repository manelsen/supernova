//// Tests for the Session Server module.
////
//// Verifies session state management: process input, history, status, model override.

import gleam/option.{None, Some}
import gleeunit/should
import supernova/core/session/server

pub fn new_session_has_idle_status_test() {
  let assert Ok(session) = server.new("test_session_001")

  let status = server.get_status(session)
  status
  |> should.equal(server.Idle)
}

pub fn new_session_has_empty_history_test() {
  let assert Ok(session) = server.new("test_session_002")

  let history = server.get_history(session)
  history
  |> should.equal([])
}

pub fn new_session_has_correct_id_test() {
  let assert Ok(session) = server.new("my_session_123")

  let id = server.get_session_id(session)
  id
  |> should.equal("my_session_123")
}

pub fn set_model_override_test() {
  let assert Ok(session) = server.new("test_session_003")

  let assert Ok(Nil) = server.set_model(session, "gpt-4")

  let model = server.get_model(session)
  model
  |> should.equal(Some("gpt-4"))
}

pub fn clear_model_override_test() {
  let assert Ok(session) = server.new("test_session_004")

  let assert Ok(Nil) = server.set_model(session, "gpt-4")
  let assert Ok(Nil) = server.clear_model(session)

  let model = server.get_model(session)
  model
  |> should.equal(None)
}

pub fn stop_session_test() {
  let assert Ok(session) = server.new("test_session_005")

  let assert Ok(Nil) = server.stop(session)
}
