//// The conversation a person has with the agent in one chat, kept on disk so
//// a restart does not cut it.
////
//// One JSONL file per session (`channel:chat:user`), under the person's agent
//// directory: `<data_dir>/agents/<person>/conversations/<session>.jsonl`.
//// Each line is one message, `{"role", "content", "at"}`. Appends go to the
//// end of the file, and nothing is ever pruned: the model sees the last
//// `limit` messages, and the agent searches the rest with `buscar_conversa`.
////
//// Only the session actor that owns a conversation writes to its file, so
//// writes to one file never race. `/esquecer` removes the whole directory.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import supernova/core/agent_identity

/// Where conversations live. `limit` is how many recent messages the model
/// sees; the disk keeps all of them.
pub type HistoryStore {
  HistoryStore(data_dir: String, limit: Int)
}

/// One stored message. `at` is the Unix time in milliseconds.
pub type StoredMessage {
  StoredMessage(role: String, content: String, at: Int)
}

/// Directory holding every conversation of a person.
pub fn dir(data_dir: String, principal: String) -> String {
  agent_identity.agent_dir(data_dir, principal) <> "/conversations"
}

/// File of one session's conversation.
pub fn path(store: HistoryStore, session_id: String) -> String {
  dir(store.data_dir, agent_identity.principal_from_session_id(session_id))
  <> "/"
  <> agent_identity.encode_principal(session_id)
  <> ".jsonl"
}

/// The most recent messages of a session, oldest first, cut to the limit and
/// opening with a user message. A missing file is an empty conversation; a
/// damaged line is skipped.
pub fn load(store: HistoryStore, session_id: String) -> List(StoredMessage) {
  read_file_messages(path(store, session_id))
  |> trim(store.limit)
  |> from_first_user
}

/// Every message in one conversation file, oldest first; a missing or
/// unreadable file is an empty conversation.
pub fn read_file_messages(file: String) -> List(StoredMessage) {
  case read_file_strict(file) {
    Ok(messages) -> messages
    Error(_) -> []
  }
}

/// Every message in one conversation file, oldest first. A missing file is
/// an empty conversation; any other failure to read it is an error, so a
/// search never mistakes it for "not said". Damaged lines are skipped.
pub fn read_file_strict(file: String) -> Result(List(StoredMessage), String) {
  case read_file(file) {
    Ok(text) ->
      Ok(
        string.split(text, "\n")
        |> list.filter(fn(line) { string.trim(line) != "" })
        |> list.filter_map(decode_line),
      )
    Error(reason) ->
      case is_missing(reason) {
        True -> Ok([])
        False -> Error(reason)
      }
  }
}

/// A read or list error that only means "not there".
pub fn is_missing(reason: String) -> Bool {
  string.contains(reason, "no such file") || string.contains(reason, "enoent")
}

/// Append messages to the end of a session's file.
pub fn append(
  store: HistoryStore,
  session_id: String,
  messages: List(StoredMessage),
) -> Result(Nil, String) {
  use _ <- result.try(
    ensure_dir(dir(
      store.data_dir,
      agent_identity.principal_from_session_id(session_id),
    )),
  )
  append_file(path(store, session_id), encode_lines(messages))
}

/// The last `limit` messages.
pub fn trim(messages: List(a), limit: Int) -> List(a) {
  messages
  |> list.drop(int_max(list.length(messages) - limit, 0))
}

/// Drop leading replies: a conversation the model sees opens with something
/// the person said.
pub fn from_first_user(messages: List(StoredMessage)) -> List(StoredMessage) {
  list.drop_while(messages, fn(message) { message.role != "user" })
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

fn encode_lines(messages: List(StoredMessage)) -> String {
  list.map(messages, fn(message) {
    json.object([
      #("role", json.string(message.role)),
      #("content", json.string(message.content)),
      #("at", json.int(message.at)),
    ])
    |> json.to_string
    |> string.append("\n")
  })
  |> string.concat
}

fn decode_line(line: String) -> Result(StoredMessage, Nil) {
  let decoder = {
    use role <- decode.field("role", decode.string)
    use content <- decode.field("content", decode.string)
    use at <- decode.optional_field("at", 0, decode.int)
    decode.success(StoredMessage(role: role, content: content, at: at))
  }
  json.parse(line, decoder) |> result.replace_error(Nil)
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "append_file")
fn append_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)
