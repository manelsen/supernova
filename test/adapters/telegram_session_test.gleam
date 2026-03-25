//// Tests for Telegram Session Manager.

import gleeunit/should
import supernova/adapters/telegram_session

pub fn session_key_test() {
  let key = telegram_session.session_key("12345")
  key
  |> should.equal("telegram:12345")
}

pub fn new_manager_test() {
  let assert Ok(mgr) = telegram_session.start()

  let sessions = telegram_session.list_sessions(mgr)
  sessions
  |> should.equal([])
}

pub fn get_or_create_test() {
  let assert Ok(mgr) = telegram_session.start()

  let assert Ok(id) = telegram_session.get_or_create(mgr, "chat_1")
  id
  |> should.equal("telegram:chat_1")
}

pub fn reuse_existing_test() {
  let assert Ok(mgr) = telegram_session.start()

  let assert Ok(id1) = telegram_session.get_or_create(mgr, "chat_1")
  let assert Ok(id2) = telegram_session.get_or_create(mgr, "chat_1")
  id1
  |> should.equal(id2)
}

pub fn different_chats_test() {
  let assert Ok(mgr) = telegram_session.start()

  let assert Ok(id1) = telegram_session.get_or_create(mgr, "chat_1")
  let assert Ok(id2) = telegram_session.get_or_create(mgr, "chat_2")
  id1
  |> should.not_equal(id2)
}

pub fn list_sessions_test() {
  let assert Ok(mgr) = telegram_session.start()

  let assert Ok(_) = telegram_session.get_or_create(mgr, "c1")
  let assert Ok(_) = telegram_session.get_or_create(mgr, "c2")

  let sessions = telegram_session.list_sessions(mgr)
  sessions
  |> should.equal(["telegram:c1", "telegram:c2"])
}
