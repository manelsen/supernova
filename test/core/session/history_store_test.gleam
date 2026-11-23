//// A conversation kept on disk survives a restart, stays within its limit,
//// opens with something the person said, skips damaged lines, and is gone
//// after /esquecer.

import exception
import gleam/list
import gleam/string
import gleeunit/should
import supernova/core/session/history_store.{HistoryStore}
import supernova/core/session/server
import supernova/core/session/supervisor
import test_workspace

const session_id = "telegram:-100:42"

fn with_store(limit: Int, body: fn(history_store.HistoryStore) -> a) -> a {
  let dir = test_workspace.create_temp_dir("history_store")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  body(HistoryStore(data_dir: dir, limit: limit))
}

fn exchange(n: Int) -> List(server.ChatMessage) {
  let n = string.inspect(n)
  [
    server.ChatMessage(role: "user", content: "pergunta " <> n),
    server.ChatMessage(role: "assistant", content: "resposta " <> n),
  ]
}

fn contents(history: List(server.ChatMessage)) -> List(String) {
  list.map(history, fn(message) { message.content })
}

pub fn a_conversation_survives_a_restart_test() {
  use store <- with_store(40)
  let assert Ok(sup) = supervisor.start_with_history(store)
  let assert Ok(session) = supervisor.start_session(sup, session_id)
  let assert Ok(Nil) = server.append_messages(session, exchange(1))
  let assert Ok(Nil) = server.append_messages(session, exchange(2))
  supervisor.stop(sup)

  // A new supervisor is what a container restart gives.
  let assert Ok(sup) = supervisor.start_with_history(store)
  let assert Ok(session) = supervisor.start_session(sup, session_id)
  server.get_history(session)
  |> should.equal(list.append(exchange(1), exchange(2)))
  supervisor.stop(sup)
}

pub fn the_file_lives_under_the_persons_agent_directory_test() {
  use store <- with_store(40)
  history_store.path(store, session_id)
  |> string.starts_with(store.data_dir <> "/agents/")
  |> should.equal(True)
  history_store.path(store, session_id)
  |> string.contains("/conversations/")
  |> should.equal(True)
}

pub fn the_conversation_keeps_only_the_most_recent_messages_test() {
  use store <- with_store(4)
  let assert Ok(session) = server.new_with_store(session_id, store)
  [1, 2, 3, 4, 5, 6, 7]
  |> list.each(fn(n) {
    let assert Ok(Nil) = server.append_messages(session, exchange(n))
    Nil
  })
  let expected = ["pergunta 6", "resposta 6", "pergunta 7", "resposta 7"]
  contents(server.get_history(session)) |> should.equal(expected)

  // A reload gives the same window.
  history_store.load(store, session_id)
  |> list.map(fn(message) { message.content })
  |> should.equal(expected)
}

pub fn an_odd_limit_still_opens_with_the_person_test() {
  use store <- with_store(3)
  let assert Ok(session) = server.new_with_store(session_id, store)
  let assert Ok(Nil) = server.append_messages(session, exchange(1))
  let assert Ok(Nil) = server.append_messages(session, exchange(2))
  // The last 3 would open with "resposta 1".
  contents(server.get_history(session))
  |> should.equal(["pergunta 2", "resposta 2"])

  let assert Ok(reloaded) = server.new_with_store(session_id, store)
  contents(server.get_history(reloaded))
  |> should.equal(["pergunta 2", "resposta 2"])
}

pub fn a_damaged_line_is_skipped_test() {
  use store <- with_store(40)
  let assert Ok(session) = server.new_with_store(session_id, store)
  let assert Ok(Nil) = server.append_messages(session, exchange(1))
  let assert Ok(Nil) =
    append_raw(history_store.path(store, session_id), "{\"role\": \n")
  let assert Ok(Nil) = server.append_messages(session, exchange(2))

  let assert Ok(reloaded) = server.new_with_store(session_id, store)
  contents(server.get_history(reloaded))
  |> should.equal(["pergunta 1", "resposta 1", "pergunta 2", "resposta 2"])
}

pub fn sessions_without_a_store_keep_memory_only_test() {
  use store <- with_store(40)
  let assert Ok(session) = server.new(session_id)
  let assert Ok(Nil) = server.append_messages(session, exchange(1))
  history_store.load(store, session_id) |> should.equal([])
}

pub fn each_person_in_a_group_has_their_own_file_test() {
  use store <- with_store(40)
  history_store.path(store, "telegram:-100:42")
  |> should.not_equal(history_store.path(store, "telegram:-100:43"))
  history_store.dir(store.data_dir, "telegram:42")
  |> should.not_equal(history_store.dir(store.data_dir, "telegram:43"))
}

@external(erlang, "supernova_file_system_ffi", "append_file")
fn append_raw(path: String, content: String) -> Result(Nil, String)

/// Nothing is pruned: the model sees the last messages, the disk keeps all.
pub fn the_disk_keeps_every_message_test() {
  let dir = test_workspace.create_temp_dir("history_store_all")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  let store = HistoryStore(data_dir: dir, limit: 2)
  let assert Ok(session) = server.new_with_store(session_id, store)
  list.repeat(Nil, 30)
  |> list.index_map(fn(_, i) { i + 1 })
  |> list.each(fn(n) {
    let assert Ok(Nil) = server.append_messages(session, exchange(n))
    Nil
  })
  contents(server.get_history(session))
  |> should.equal(["pergunta 30", "resposta 30"])
  history_store.load(store, session_id)
  |> list.map(fn(message) { message.content })
  |> should.equal(["pergunta 30", "resposta 30"])
  let wide = HistoryStore(data_dir: dir, limit: 1000)
  let all = history_store.load(wide, session_id)
  list.length(all) |> should.equal(60)
  let assert [first, ..] = all
  first.content |> should.equal("pergunta 1")
}

/// The window comes from the end of the file, read backwards: the last
/// messages of a long conversation, whole even when one is longer than a
/// read chunk, and the same with or without the last line break.
pub fn the_window_is_read_from_the_end_of_the_file_test() {
  let dir = test_workspace.create_temp_dir("history_store_tail")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  let store = HistoryStore(data_dir: dir, limit: 4)
  let long = string.repeat("x", 200_000)
  let messages =
    list.repeat(Nil, 10_000)
    |> list.index_map(fn(_, i) {
      let content = case i {
        9998 -> long
        _ -> "m" <> string.inspect(i)
      }
      history_store.StoredMessage(
        role: case i % 2 {
          0 -> "user"
          _ -> "assistant"
        },
        content: content,
        at: i,
      )
    })
  let assert Ok(Nil) = history_store.append(store, session_id, messages)
  let window = history_store.load(store, session_id)
  list.map(window, fn(m) { m.content })
  |> should.equal(["m9996", "m9997", long, "m9999"])

  // Without the final line break, the last line is still whole.
  let file = history_store.path(store, session_id)
  let assert Ok(text) = read_text(file)
  let assert Ok(Nil) = write_text(file, string.drop_end(text, 1))
  let assert Ok(last) = list.last(history_store.load(store, session_id))
  last.content |> should.equal("m9999")

  history_store.load(store, "telegram:-100:nobody") |> should.equal([])
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_text(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_text(path: String, content: String) -> Result(Nil, String)
