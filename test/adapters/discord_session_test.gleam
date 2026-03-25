//// Tests for Discord Session Manager.

import gleeunit/should
import supernova/adapters/discord_session

pub fn create_session_key_test() {
  let key = discord_session.session_key("123456", "789012")
  key
  |> should.equal("123456:789012")
}

pub fn new_manager_has_no_sessions_test() {
  let assert Ok(mgr) = discord_session.start()

  let sessions = discord_session.list_sessions(mgr)
  sessions
  |> should.equal([])
}

pub fn get_or_create_session_test() {
  let assert Ok(mgr) = discord_session.start()

  let assert Ok(session_id) =
    discord_session.get_or_create(mgr, "channel_1", "user_1")

  // Should return a session ID
  session_id
  |> should.equal("discord:channel_1:user_1")
}

pub fn get_existing_session_test() {
  let assert Ok(mgr) = discord_session.start()

  let assert Ok(id1) = discord_session.get_or_create(mgr, "ch1", "u1")
  let assert Ok(id2) = discord_session.get_or_create(mgr, "ch1", "u1")

  // Same channel+user should return same session
  id1
  |> should.equal(id2)
}

pub fn different_users_different_sessions_test() {
  let assert Ok(mgr) = discord_session.start()

  let assert Ok(id1) = discord_session.get_or_create(mgr, "ch1", "u1")
  let assert Ok(id2) = discord_session.get_or_create(mgr, "ch1", "u2")

  id1
  |> should.not_equal(id2)
}

pub fn list_sessions_test() {
  let assert Ok(mgr) = discord_session.start()

  let assert Ok(_) = discord_session.get_or_create(mgr, "ch1", "u1")
  let assert Ok(_) = discord_session.get_or_create(mgr, "ch2", "u2")

  let sessions = discord_session.list_sessions(mgr)
  sessions
  |> should.equal(["discord:ch1:u1", "discord:ch2:u2"])
}
