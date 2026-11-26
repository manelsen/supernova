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
//// One actor owns the file. Writes are grouped: the messages and done marks
//// already waiting in its mailbox when one arrives go to disk in one
//// append, and each sender is answered only after that append (PRD-P,
//// P-06). Interactions (button presses) are not kept:
//// replaying one after a restart could repeat an action.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/result
import gleam/string
import supernova/aprovacao/senha
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
  Pending(
    key: String,
    message: port.ChannelMessage,
    at: Int,
    attempts: Int,
    /// Arrival order, for messages that share a millisecond.
    seq: Int,
  )
}

pub opaque type Message {
  Receive(reply_to: Subject(Bool), message: port.ChannelMessage, now: Int)
  Done(key: String, now: Int)
  Recover(reply_to: Subject(List(Pending)), now: Int)
  Forget(reply_to: Subject(Result(Int, String)), principal: String, now: Int)
  Count(reply_to: Subject(#(Int, Int)))
  Writes(reply_to: Subject(Int))
  Stop(reply_to: Subject(Nil))
}

/// Most messages taken from the mailbox into one append.
const batch_limit = 512

type State {
  State(
    file: String,
    pending: Dict(String, Pending),
    /// Every key seen in the last day, with when it was seen.
    seen: Dict(String, Int),
    lines: Int,
    next_seq: Int,
    /// Appends made, for tests of the grouping.
    writes: Int,
    me: Option(Subject(Message)),
  )
}

/// Key of a message: the same message delivered twice has the same key.
pub fn key(message: port.ChannelMessage) -> String {
  message.channel <> "|" <> message.channel_id <> "|" <> message.id
}

/// Start the inbox over `<data_dir>/inbox.jsonl`, loading what it holds.
/// Only one inbox may own the file: stop the previous one first (`stop`).
pub fn start(data_dir: String) -> Result(Inbox, actor.StartError) {
  let file = data_dir <> "/inbox.jsonl"
  let _ = ensure_dir(data_dir)
  let state = load(file)
  actor.new_with_initialiser(5000, fn(me) {
    actor.initialised(State(..state, me: Some(me)))
    |> actor.returning(me)
    |> Ok
  })
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

/// Messages still pending from before the restart, in arrival order, to
/// answer again. Call it once, before any channel starts: what arrives
/// afterwards is never in this list. Each message comes back once: one that
/// was already tried, or that is older than a day, is dropped and logged.
pub fn recover(inbox: Inbox, now: Int) -> List(Pending) {
  actor.call(inbox, waiting: 5000, sending: Recover(_, now))
}

/// Erase what a person sent (`/esquecer`): their pending messages leave the
/// inbox, so a restart does not answer them, and the log is rewritten at
/// once, without the text of any message whose turn is done. Returns how
/// many pending messages were dropped.
/// Drop the person's waiting messages and rewrite the log without them.
/// An error means the log on disk may still hold them: call again.
pub fn forget(
  inbox: Inbox,
  principal: String,
  now: Int,
) -> Result(Int, String) {
  actor.call(inbox, waiting: 5000, sending: Forget(_, principal, now))
}

/// Write everything sent before this call, then stop. Shutdown calls it
/// after the lanes drain, so the last `done` marks reach the disk.
pub fn stop(inbox: Inbox) -> Nil {
  actor.call(inbox, waiting: 5000, sending: Stop)
}

/// How many messages are pending and how many keys are remembered.
pub fn count(inbox: Inbox) -> #(Int, Int) {
  actor.call(inbox, waiting: 5000, sending: Count)
}

/// How many appends the inbox has made since it started.
pub fn writes(inbox: Inbox) -> Int {
  actor.call(inbox, waiting: 5000, sending: Writes)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Receive(..) | Done(..) -> {
      let #(batch, next) = take_batch(state.me, [message], 1)
      let state = write_batch(state, batch)
      case next {
        Some(other) -> handle(state, other)
        None -> actor.continue(state)
      }
    }

    Writes(reply_to) -> {
      actor.send(reply_to, state.writes)
      actor.continue(state)
    }

    Recover(reply_to, now) -> {
      let #(retry, drop) =
        dict.values(state.pending)
        |> list.sort(fn(a, b) {
          case int.compare(a.at, b.at) {
            order.Eq -> int.compare(a.seq, b.seq)
            other -> other
          }
        })
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
        list.fold(drop, state.pending, fn(acc, entry) {
          dict.delete(acc, entry.key)
        })
      let pending =
        list.fold(retry, pending, fn(acc, entry) {
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

    Forget(reply_to, principal, now) -> {
      let #(gone, kept) =
        dict.to_list(state.pending)
        |> list.partition(fn(pair) { principal_of(pair.1.message) == principal })
      let state = State(..state, pending: dict.from_list(kept))
      // The person was told they are forgotten only if the disk says so.
      case try_compact(state, now) {
        Ok(state) -> {
          actor.send(reply_to, Ok(list.length(gone)))
          actor.continue(state)
        }
        Error(reason) -> {
          actor.send(reply_to, Error(reason))
          actor.continue(state)
        }
      }
    }

    Count(reply_to) -> {
      actor.send(reply_to, #(dict.size(state.pending), dict.size(state.seen)))
      actor.continue(state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

/// The receives and done marks already in the mailbox, in order, up to
/// `batch_limit`; and the first other message, if one ended the batch.
fn take_batch(
  me: Option(Subject(Message)),
  batch: List(Message),
  size: Int,
) -> #(List(Message), Option(Message)) {
  case me, size >= batch_limit {
    Some(subject), False ->
      case process.receive(subject, within: 0) {
        Ok(Receive(..) as next) | Ok(Done(..) as next) ->
          take_batch(me, [next, ..batch], size + 1)
        Ok(other) -> #(list.reverse(batch), Some(other))
        Error(Nil) -> #(list.reverse(batch), None)
      }
    _, _ -> #(list.reverse(batch), None)
  }
}

/// Apply a batch of receives and done marks, write their lines in one
/// append, then answer the receives: a sender hears "kept" only once its
/// message is on disk.
fn write_batch(state: State, batch: List(Message)) -> State {
  let #(state, lines, replies, now) =
    list.fold(batch, #(state, [], [], 0), fn(acc, message) {
      let #(state, lines, replies, last) = acc
      case message {
        Receive(reply_to, channel_message, now) -> {
          let key = key(channel_message)
          case dict.has_key(state.seen, key) {
            True -> #(state, lines, [#(reply_to, False), ..replies], now)
            False -> {
              let entry = Pending(key, channel_message, now, 0, state.next_seq)
              #(
                State(
                  ..state,
                  pending: dict.insert(state.pending, key, entry),
                  seen: dict.insert(state.seen, key, now),
                  next_seq: state.next_seq + 1,
                ),
                [encode_in(entry), ..lines],
                [#(reply_to, True), ..replies],
                now,
              )
            }
          }
        }
        Done(key, now) ->
          case dict.has_key(state.pending, key) {
            False -> #(state, lines, replies, last)
            True -> #(
              State(..state, pending: dict.delete(state.pending, key)),
              [encode_done(key, now), ..lines],
              replies,
              now,
            )
          }
        _ -> acc
      }
    })
  let state = case lines {
    [] -> state
    _ -> write(state, list.reverse(lines), now)
  }
  list.each(list.reverse(replies), fn(reply) { actor.send(reply.0, reply.1) })
  state
}

fn principal_of(message: port.ChannelMessage) -> String {
  message.channel <> ":" <> message.user_id
}

/// Append lines; compact the log when it has grown.
fn write(state: State, lines: List(String), now: Int) -> State {
  let appended = case append_raw(state.file, string.concat(lines)) {
    Ok(Nil) -> list.length(lines)
    Error(reason) -> {
      safe_io.println("warn: inbox not saved error=" <> reason)
      0
    }
  }
  let state =
    State(..state, lines: state.lines + appended, writes: state.writes + 1)
  // Compact when the log is twice what it must keep, so a busy day (more
  // keys to remember than `compact_after`) does not rewrite it every time.
  case state.lines >= compact_after + dict.size(state.seen) {
    False -> state
    True -> compact(state, now)
  }
}

/// Rewrite the log with the pending messages and the keys of the last day.
/// A failure keeps the old log and is only a warning here: the next
/// compaction tries again.
fn compact(state: State, now: Int) -> State {
  case try_compact(state, now) {
    Ok(state) -> state
    Error(reason) -> {
      safe_io.println("warn: inbox not compacted error=" <> reason)
      state
    }
  }
}

fn try_compact(state: State, now: Int) -> Result(State, String) {
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
        Ok(Nil) -> Ok(State(..state, seen: seen, lines: list.length(lines)))
        Error(reason) -> Error(reason)
      }
    Error(reason) -> Error(reason)
  }
}

fn load(file: String) -> State {
  let empty =
    State(
      file: file,
      pending: dict.new(),
      seen: dict.new(),
      lines: 0,
      next_seq: 0,
      writes: 0,
      me: None,
    )
  case read_file(file) {
    Error(_) -> empty
    Ok(text) -> {
      // A write cut short leaves a line without its end; the next record
      // must start on a line of its own, or it would be lost with it.
      case text != "" && !string.ends_with(text, "\n") {
        True -> {
          let _ = append_raw(file, "\n")
          Nil
        }
        False -> Nil
      }
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
      use seq <- decode.optional_field("seq", 0, decode.int)
      use message <- decode.field("message", message_decoder())
      decode.success(In(Pending(key, message, at, attempts, seq)))
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
  // A password given by /senha never reaches the disk (PRD-K, K-I3); a
  // replay after a crash finds the command without it, and asks again.
  let message =
    port.ChannelMessage(
      ..entry.message,
      content: senha.redact(entry.message.content),
    )
  json.object([
    #("ev", json.string("in")),
    #("key", json.string(entry.key)),
    #("at", json.int(entry.at)),
    #("attempts", json.int(entry.attempts)),
    #("seq", json.int(entry.seq)),
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

/// Raw append (no file server, no process spawned per write).
@external(erlang, "supernova_file_system_ffi", "append_file")
fn append_raw(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_self_ffi", "rename_file")
fn rename(from: String, to: String) -> Result(Nil, String)
