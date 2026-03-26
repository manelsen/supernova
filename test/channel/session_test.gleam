import gleeunit/should
import supernova/channel/session

pub fn without_manager_test() {
  let resolver = session.without_manager("matrix")
  let session_id = resolver.resolve("room_123", "user_456")

  session_id
  |> should.equal("matrix:room_123:user_456")
}

pub fn without_manager_empty_ids_test() {
  let resolver = session.without_manager("slack")
  let session_id = resolver.resolve("", "")

  session_id
  |> should.equal("slack::")
}

pub fn with_manager_success_test() {
  let resolver = session.with_manager(fn(channel_id, user_id) {
    channel_id <> "_" <> user_id
  })

  let session_id = resolver.resolve("ch1", "u1")

  session_id
  |> should.equal("ch1_u1")
}

pub fn with_manager_empty_result_test() {
  let resolver = session.with_manager(fn(_channel_id, _user_id) {
    ""
  })

  let session_id = resolver.resolve("ch1", "u1")

  session_id
  |> should.equal("session:ch1:u1")
}
