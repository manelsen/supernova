//// Durable inbox: every message a channel delivers is written to disk before
//// it enters its chat's lane, and marked done when its turn ends. A restart
//// (a deploy, a crash) therefore loses nothing that was waiting in a lane,
//// and a message the channel delivers twice is answered once.
////
//// Telegram treats a fetched update as delivered only when the next
//// `getUpdates` asks for a later offset, so the last batch fetched before a
//// shutdown comes back after the restart; the inbox recognises it.
////
//// The log is one JSONL file, `<data_dir>/inbox.jsonl`, with two kinds of
//// line: `{"ev":"in", "key", "at", "attempts", "message"}` when a message
//// arrives and `{"ev":"done", "key", "at"}` when its turn ends. It is
//// rewritten (tmp + rename) when it grows, keeping the pending messages and
//// the keys seen in the last day; the text of a message leaves the disk once
//// its turn is done and the log is compacted.
////
//// One actor owns the file. Interactions (button presses) are not kept:
//// replaying one after a restart could repeat an action.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import supernova/channel/port
import supernova/infra/safe_io

/// How long a message is remembered, to recognise a second delivery, and
/// how old a pending message may be to still be answered after a restart.
pub const memory_ms = 86_400_000

/// Lines in the log before it is compacted.
const compact_after = 2000

pub type Inbox =
  Subject(Message)

/// A message that arrived and whose turn did not end.
pub type Pending {
  Pending(key: String, message: port.ChannelMessage, at: Int, attempts: Int)
}

pub opaque type Message {
  Receive(reply_to: Subject(Bool), message: port.ChannelMessage, now: Int)
  Done(key: String, now: Int)
  Recover(reply_to: Subject(List(Pending)), now: Int)
  Count(reply_to: Subject(#(Int, Int)))
}

type State {
  State(
    file: String,
    pending: Dict(String, Pending),
    /// Every key seen in the last day, with when it was seen.
    seen: Dict(String, Int),
    lines: Int,
  )
}

/// Key of a message: the same message delivered twice has the same key.
pub fn key(message: port.ChannelMessage) -> String {
  message.channel <> "|" <> message.channel_id <> "|" <> message.id
}

/// Start the inbox over `<data_dir>/inbox.jsonl`, loading what it holds.
pub fn start(data_dir: String) -> Result(Inbox, actor.StartError) {
  let file = data_dir <> "/inbox.jsonl"
  let _ = ensure_dir(data_dir)
  let state = load(file)
  actor.new(state)
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// Record a message before its turn. False when it was already seen: the
/// channel delivered it again and it must not be answered twice.
pub fn receive(inbox: Inbox, message: port.ChannelMessage, now: Int) -> Bool {
  actor.call(inbox, waiting: 5000, sending: Receive(_, message, now))
}

/// The turn of the message with this key ended (answered or not).
pub fn done(inbox: Inbox, key: String, now: Int) -> Nil {
  actor.send(inbox, Done(key, now))
}

/// Messages still pending from before the restart, oldest first, to answer
/// again. Each comes back once: one that was already tried, or that is older
/// than a day, is dropped and logged instead.
pub fn recover(inbox: Inbox, now: Int) -> List(Pending) {
  actor.call(inbox, waiting: 5000, sending: Recover(_, now))
}

/// How many messages are pending and how many keys are remembered.
pub fn count(inbox: Inbox) -> #(Int, Int) {
  actor.call(inbox, waiting: 5000, sending: Count)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Receive(reply_to, channel_message, now) -> {
      let key = key(channel_message)
      case dict.has_key(state.seen, key) {
        True -> {
          actor.send(reply_to, False)
          actor.continue(state)
        }
        False -> {
          let entry = Pending(key, channel_message, now, 0)
          let state =
            State(
              ..state,
              pending: dict.insert(state.pending, key, entry),
              seen: dict.insert(state.seen, key, now),
            )
            |> write([encode_in(entry)], now)
          actor.send(reply_to, True)
          actor.continue(state)
        }
      }
    }

    Done(key, now) ->
      case dict.has_key(state.pending, key) {
        False -> actor.continue(state)
        True ->
          State(..state, pending: dict.delete(state.pending, key))
          |> write([encode_done(key, now)], now)
          |> actor.continue
      }

    Recover(reply_to, now) -> {
      let #(retry, drop) =
        dict.values(state.pending)
        |> list.sort(fn(a, b) { int.compare(a.at, b.at) })
        |> list.partition(fn(entry) {
          entry.attempts == 0 && now - entry.at <= memory_ms
        })
      list.each(drop, fn(entry) {
        safe_io.println(
          "warn: inbox dropped a message that did not finish after a restart key="
          <> entry.key,
        )
      })
      let retry = list.map(retry, fn(entry) { Pending(..entry, attempts: 1) })
      let pending =
        list.fold(retry, dict.new(), fn(acc, entry) {
          dict.insert(acc, entry.key, entry)
        })
      let lines =
        list.append(
          list.map(drop, fn(entry) { encode_done(entry.key, now) }),
          list.map(retry, encode_in),
        )
      let state = State(..state, pending: pending) |> write(lines, now)
      actor.send(reply_to, retry)
      actor.continue(state)
    }

    Count(reply_to) -> {
      actor.send(reply_to, #(dict.size(state.pending), dict.size(state.seen)))
      actor.continue(state)
    }
  }
}

/// Append lines; compact the log when it has grown.
fn write(state: State, lines: List(String), now: Int) -> State {
  let appended = case append_file(state.file, string.concat(lines)) {
    Ok(Nil) -> list.length(lines)
    Error(reason) -> {
      safe_io.println("warn: inbox not saved error=" <> reason)
      0
    }
  }
  let state = State(..state, lines: state.lines + appended)
  case state.lines >= compact_after {
    False -> state
    True -> compact(state, now)
  }
}

/// Rewrite the log with the pending messages and the keys of the last day.
fn compact(state: State, now: Int) -> State {
  let seen = dict.filter(state.seen, fn(_, at) { now - at <= memory_ms })
  let done_lines =
    dict.to_list(seen)
    |> list.filter(fn(pair) { !dict.has_key(state.pending, pair.0) })
    |> list.map(fn(pair) { encode_done(pair.0, pair.1) })
  let in_lines = dict.values(state.pending) |> list.map(encode_in)
  let lines = list.append(in_lines, done_lines)
  let tmp = state.file <> ".tmp"
  case write_file(tmp, string.concat(lines)) {
    Ok(Nil) ->
      case rename(tmp, state.file) {
        Ok(Nil) -> State(..state, seen: seen, lines: list.length(lines))
        Error(reason) -> {
          safe_io.println("warn: inbox not compacted error=" <> reason)
          state
        }
      }
    Error(reason) -> {
      safe_io.println("warn: inbox not compacted error=" <> reason)
      state
    }
  }
}

fn load(file: String) -> State {
  let empty = State(file: file, pending: dict.new(), seen: dict.new(), lines: 0)
  case read_file(file) {
    Error(_) -> empty
    Ok(text) -> {
      let lines =
        string.split(text, "\n")
        |> list.filter(fn(line) { string.trim(line) != "" })
      list.fold(
        lines,
        State(..empty, lines: list.length(lines)),
        fn(state, line) {
          case json.parse(line, event_decoder()) {
            Ok(In(entry)) ->
              State(
                ..state,
                pending: dict.insert(state.pending, entry.key, entry),
                seen: dict.insert(state.seen, entry.key, entry.at),
              )
            Ok(Out(key, at)) ->
              State(
                ..state,
                pending: dict.delete(state.pending, key),
                seen: dict.insert(state.seen, key, at),
              )
            Error(_) -> state
          }
        },
      )
    }
  }
}

type Event {
  In(Pending)
  Out(key: String, at: Int)
}

fn event_decoder() -> decode.Decoder(Event) {
  use ev <- decode.field("ev", decode.string)
  case ev {
    "in" -> {
      use key <- decode.field("key", decode.string)
      use at <- decode.field("at", decode.int)
      use attempts <- decode.field("attempts", decode.int)
      use message <- decode.field("message", message_decoder())
      decode.success(In(Pending(key, message, at, attempts)))
    }
    _ -> {
      use key <- decode.field("key", decode.string)
      use at <- decode.field("at", decode.int)
      decode.success(Out(key, at))
    }
  }
}

fn message_decoder() -> decode.Decoder(port.ChannelMessage) {
  use id <- decode.field("id", decode.string)
  use channel <- decode.field("channel", decode.string)
  use channel_id <- decode.field("channel_id", decode.string)
  use user_id <- decode.field("user_id", decode.string)
  use username <- decode.field("username", decode.string)
  use content <- decode.field("content", decode.string)
  use is_bot <- decode.field("is_bot", decode.bool)
  use reply_to_id <- decode.field("reply_to_id", decode.optional(decode.string))
  decode.success(port.ChannelMessage(
    id: id,
    channel: channel,
    channel_id: channel_id,
    user_id: user_id,
    username: username,
    content: content,
    is_bot: is_bot,
    reply_to_id: reply_to_id,
  ))
}

fn encode_in(entry: Pending) -> String {
  let message = entry.message
  json.object([
    #("ev", json.string("in")),
    #("key", json.string(entry.key)),
    #("at", json.int(entry.at)),
    #("attempts", json.int(entry.attempts)),
    #(
      "message",
      json.object([
        #("id", json.string(message.id)),
        #("channel", json.string(message.channel)),
        #("channel_id", json.string(message.channel_id)),
        #("user_id", json.string(message.user_id)),
        #("username", json.string(message.username)),
        #("content", json.string(message.content)),
        #("is_bot", json.bool(message.is_bot)),
        #("reply_to_id", json.nullable(message.reply_to_id, json.string)),
      ]),
    ),
  ])
  |> json.to_string
  |> string.append("\n")
}

fn encode_done(key: String, at: Int) -> String {
  json.object([
    #("ev", json.string("done")),
    #("key", json.string(key)),
    #("at", json.int(at)),
  ])
  |> json.to_string
  |> string.append("\n")
}

// ============================================================================
// Global registration
// ============================================================================

const global_key = "supernova_global_inbox"

pub fn set_global(inbox: Inbox) -> Nil {
  global_put(global_key, inbox)
}

/// The registered inbox, if one is running. Without one (tests, or a boot
/// that could not open the file), messages go straight to their lanes.
pub fn global() -> Option(Inbox) {
  case global_lookup(global_key) {
    Ok(inbox) ->
      case subject_alive(inbox) {
        True -> Some(inbox)
        False -> None
      }
    Error(Nil) -> None
  }
}

pub fn clear_global() -> Nil {
  global_erase(global_key)
}

fn subject_alive(inbox: Inbox) -> Bool {
  case process.subject_owner(inbox) {
    Ok(pid) -> process.is_alive(pid)
    Error(Nil) -> False
  }
}

@external(erlang, "supernova_global_ffi", "global_erase")
fn global_erase(key: String) -> Nil

@external(erlang, "supernova_global_ffi", "global_lookup")
fn global_lookup(key: String) -> Result(a, Nil)

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: any) -> Nil

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "append_file")
fn append_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_self_ffi", "rename_file")
fn rename(from: String, to: String) -> Result(Nil, String)
