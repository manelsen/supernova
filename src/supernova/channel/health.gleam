//// Readiness of each channel, as reported by the channel itself.
////
//// The registry marks a channel started or failed. A channel that polls (such
//// as Telegram) also reports every poll; when it is started with a silence
//// limit, it stops counting as ready once no poll has succeeded within that
//// limit, which also covers a polling process that died.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import supernova/health/types as health_types
import supernova/metrics/record

pub type ChannelHealth =
  Subject(Message)

pub opaque type Message {
  Started(name: String, max_silence_ms: Option(Int), now_ms: Int)
  Failed(name: String, reason: String)
  Report(name: String, outcome: Result(Nil, String), now_ms: Int)
  Snapshot(now_ms: Int, reply: Subject(List(health_types.ChannelStatus)))
}

type Entry {
  Entry(
    error: Option(String),
    last_ok_ms: Int,
    max_silence_ms: Option(Int),
    started: Bool,
  )
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
pub fn now_ms() -> Int

pub fn start() -> ChannelHealth {
  let assert Ok(started) =
    actor.new(dict.new())
    |> actor.on_message(handle)
    |> actor.start
  started.data
}

/// The channel started. `max_silence_ms` is set for channels that report
/// every poll.
pub fn started(
  health: ChannelHealth,
  name: String,
  max_silence_ms: Option(Int),
  now_ms: Int,
) -> Nil {
  process.send(health, Started(name, max_silence_ms, now_ms))
}

/// The channel is enabled but could not start.
pub fn failed(health: ChannelHealth, name: String, reason: String) -> Nil {
  process.send(health, Failed(name, reason))
}

/// Outcome of one poll or connection attempt.
pub fn report(
  health: ChannelHealth,
  name: String,
  outcome: Result(Nil, String),
  now_ms: Int,
) -> Nil {
  case outcome {
    Ok(Nil) -> Nil
    Error(_) -> record.count("channel_poll_errors_total", [#("channel", name)])
  }
  process.send(health, Report(name, outcome, now_ms))
}

/// Status of every known channel, sorted by name.
pub fn snapshot(
  health: ChannelHealth,
  now_ms: Int,
) -> List(health_types.ChannelStatus) {
  process.call(health, 1000, Snapshot(now_ms, _))
}

fn handle(
  state: Dict(String, Entry),
  message: Message,
) -> actor.Next(Dict(String, Entry), Message) {
  case message {
    Started(name, max_silence_ms, now_ms) ->
      actor.continue(dict.insert(
        state,
        name,
        Entry(
          error: None,
          last_ok_ms: now_ms,
          max_silence_ms: max_silence_ms,
          started: True,
        ),
      ))
    Failed(name, reason) ->
      actor.continue(dict.insert(
        state,
        name,
        Entry(
          error: Some(reason),
          last_ok_ms: 0,
          max_silence_ms: None,
          started: False,
        ),
      ))
    Report(name, outcome, now_ms) ->
      case dict.get(state, name) {
        Error(_) -> actor.continue(state)
        Ok(entry) -> {
          let entry = case outcome {
            Ok(Nil) -> Entry(..entry, error: None, last_ok_ms: now_ms)
            Error(reason) -> Entry(..entry, error: Some(reason))
          }
          actor.continue(dict.insert(state, name, entry))
        }
      }
    Snapshot(now_ms, reply) -> {
      let statuses =
        state
        |> dict.to_list
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.map(fn(pair) { status(pair.0, pair.1, now_ms) })
      process.send(reply, statuses)
      actor.continue(state)
    }
  }
}

fn status(
  name: String,
  entry: Entry,
  now_ms: Int,
) -> health_types.ChannelStatus {
  let silent = case entry.max_silence_ms {
    Some(limit) -> now_ms - entry.last_ok_ms > limit
    None -> False
  }
  case entry.started, entry.error, silent {
    False, error, _ ->
      health_types.ChannelStatus(name: name, ready: False, error: error)
    True, Some(reason), _ ->
      health_types.ChannelStatus(name: name, ready: False, error: Some(reason))
    True, None, True -> {
      let limit_s = option.unwrap(entry.max_silence_ms, 0) / 1000
      health_types.ChannelStatus(
        name: name,
        ready: False,
        error: Some("no successful poll for " <> int.to_string(limit_s) <> "s"),
      )
    }
    True, None, False ->
      health_types.ChannelStatus(name: name, ready: True, error: None)
  }
}
