//// Plumbing shared by the channel runtimes: start hooks, turn dispatch and
//// generic streaming. Nothing here knows a specific channel.

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/adapters/discord_gateway
import supernova/adapters/telegram
import supernova/channel/catalog
import supernova/channel/chat_lanes
import supernova/channel/chunking
import supernova/channel/inbox
import supernova/channel/port
import supernova/infra/safe_io
import supernova/metrics/record

/// Optional hooks for deterministic bootstrap tests.
pub type StartHooks {
  StartHooks(
    discord_events: List(discord_gateway.DiscordEvent),
    telegram_updates: List(telegram.Update),
    slack_inbound_events: List(port.ChannelInbound),
    matrix_inbound_events: List(port.ChannelInbound),
    disable_telegram_polling: Bool,
    typing_keepalive_ms: Int,
    /// Timeout of recorded (test) streams. Live streams always wait
    /// `stream_timeout_ms` (60 s).
    stream_timeout_ms: Int,
    turn_hard_timeout_ms: Int,
    registry_id: String,
    outbound_records: Option(process.Subject(OutboundRecord)),
    leave_group: Option(fn(String) -> Bool),
    leave_retry_ms: List(Int),
    /// Wait before checking a group again when access was unavailable.
    leave_recheck_ms: Int,
  )
}

/// Test-only outbound observation record for channel runtime sends/edits.
pub type OutboundRecord {
  OutboundRecord(
    channel: String,
    action: String,
    content: String,
    message_id: Option(String),
  )
}

pub type StreamSendFn =
  fn(port.ChannelReply, process.Subject(port.ChannelStreamEvent)) ->
    Result(Nil, port.ChannelError)

const default_typing_keepalive_ms = 4000

pub const stream_timeout_ms = 60_000

pub const turn_hard_timeout_ms = 300_000

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
pub fn current_timestamp() -> Int

// ============================================================================
// Public API
// ============================================================================

/// Build empty bootstrap hooks for production startup.
pub fn no_start_hooks() -> StartHooks {
  StartHooks(
    discord_events: [],
    telegram_updates: [],
    slack_inbound_events: [],
    matrix_inbound_events: [],
    disable_telegram_polling: False,
    typing_keepalive_ms: default_typing_keepalive_ms,
    stream_timeout_ms: 60_000,
    turn_hard_timeout_ms: turn_hard_timeout_ms,
    registry_id: "",
    outbound_records: None,
    leave_group: None,
    leave_retry_ms: [5000, 30_000, 120_000],
    leave_recheck_ms: 30_000,
  )
}

/// Hand the inbound turn to the lane of its chat and return immediately.
///
/// The polling loop must never wait for a turn: a slow LLM or tool call
/// would hold every other chat of the channel. Turns of the same chat stay
/// ordered inside their lane.
///
/// A message goes through the durable inbox first (when one is running): it
/// is written to disk before entering the lane and marked done when its turn
/// ends, and a message the channel delivers twice is answered once.
pub fn dispatch_inbound(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: StreamSendFn,
  inbound: port.ChannelInbound,
  registry_id: String,
  turn_hard_timeout_ms: Int,
) -> Nil {
  case admit(inbound) {
    False -> Nil
    True ->
      dispatch_admitted(
        handler,
        send_fn,
        stream_send_fn,
        inbound,
        registry_id,
        turn_hard_timeout_ms,
      )
  }
}

/// Answer a message the inbox kept from before a restart. It is already on
/// disk, so it skips the duplicate check that would otherwise drop it.
pub fn dispatch_recovered(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: StreamSendFn,
  message: port.ChannelMessage,
  registry_id: String,
  turn_hard_timeout_ms: Int,
) -> Nil {
  dispatch_admitted(
    handler,
    send_fn,
    stream_send_fn,
    port.InboundMessage(message),
    registry_id,
    turn_hard_timeout_ms,
  )
}

/// Record a message in the inbox; False when the channel delivered it again.
fn admit(inbound: port.ChannelInbound) -> Bool {
  case inbound, inbox.global() {
    port.InboundMessage(message), Some(box) ->
      case inbox.receive(box, message, current_timestamp()) {
        True -> True
        False -> {
          record.count("inbox_duplicates_total", [
            #("channel", message.channel),
          ])
          False
        }
      }
    _, _ -> True
  }
}

/// The turn of a message ended, answered or not: it leaves the inbox.
fn finish(inbound: port.ChannelInbound) -> Nil {
  case inbound, inbox.global() {
    port.InboundMessage(message), Some(box) ->
      inbox.done(box, inbox.key(message), current_timestamp())
    _, _ -> Nil
  }
}

fn dispatch_admitted(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: StreamSendFn,
  inbound: port.ChannelInbound,
  registry_id: String,
  turn_hard_timeout_ms: Int,
) -> Nil {
  let key = chat_lanes.key_for_registry(registry_id, inbound)
  let #(channel, kind) = case inbound {
    port.InboundMessage(message) -> #(message.channel, "message")
    port.InboundInteraction(interaction) -> #(
      interaction.channel,
      "interaction",
    )
  }
  record.count("channel_messages_total", [
    #("channel", channel),
    #("kind", kind),
  ])
  let accepted =
    chat_lanes.submit(key, fn() {
      run_inbound_turn(
        handler,
        send_fn,
        stream_send_fn,
        inbound,
        key,
        turn_hard_timeout_ms,
      )
      finish(inbound)
    })
  case accepted {
    True -> Nil
    // Too many pending turns in this chat, or too many chats at once.
    False -> {
      record.count("chat_lane_rejected_total", [#("channel", channel)])
      finish(inbound)
    }
  }
  Nil
}

fn run_inbound_turn(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: StreamSendFn,
  inbound: port.ChannelInbound,
  chat_key: String,
  turn_hard_timeout_ms: Int,
) -> Nil {
  let started = current_timestamp()
  let channel = case inbound {
    port.InboundMessage(message) -> message.channel
    port.InboundInteraction(interaction) -> interaction.channel
  }
  let stream_events = process.new_subject()

  let outcome = case handler(inbound, stream_events) {
    Ok(port.ImmediateReply(reply)) ->
      case send_fn(reply) {
        Ok(_) -> "replied"
        Error(error) -> send_failed(channel, error)
      }
    Ok(port.StreamReply(base_reply)) -> {
      case stream_send_fn(base_reply, stream_events) {
        Ok(_) -> "streamed"
        Error(port.SendFailed("stream timed out")) -> {
          await_late_terminal(
            stream_events,
            send_fn,
            base_reply,
            chat_key,
            current_timestamp() + turn_hard_timeout_ms,
          )
          "stream_timeout"
        }
        Error(error) -> send_failed(channel, error)
      }
    }
    Error(port.Ignored(_)) -> "ignored"
    Error(_) -> "handler_error"
  }
  record.duration_ms("turn_duration_seconds", current_timestamp() - started, [
    #("channel", channel),
    #("outcome", outcome),
  ])
}

const turn_outcomes = [
  "replied", "streamed", "stream_timeout", "send_error", "ignored",
  "handler_error",
]

const send_error_kinds = [
  "send_failed",
  "rate_limited",
  "not_connected",
  "other",
]

/// Publish a channel's series at zero, so the first event after a restart is
/// counted too (see `record.declare`). Called at boot for every channel.
pub fn declare_metrics(channel: String) -> Nil {
  list.each(["message", "interaction"], fn(kind) {
    record.declare("channel_messages_total", [
      #("channel", channel),
      #("kind", kind),
    ])
  })
  record.declare("chat_lane_rejected_total", [#("channel", channel)])
  record.declare("inbox_duplicates_total", [#("channel", channel)])
  record.declare("channel_poll_errors_total", [#("channel", channel)])
  list.each(send_error_kinds, fn(kind) {
    record.declare("channel_send_errors_total", [
      #("channel", channel),
      #("error", kind),
    ])
  })
  list.each(turn_outcomes, fn(outcome) {
    record.declare_duration("turn_duration_seconds", [
      #("channel", channel),
      #("outcome", outcome),
    ])
  })
}

/// A reply that did not reach the person: counted and logged, never silent.
fn send_failed(channel: String, error: port.ChannelError) -> String {
  let kind = case error {
    port.RateLimited(_) -> "rate_limited"
    port.NotConnected -> "not_connected"
    port.SendFailed(_) -> "send_failed"
    _ -> "other"
  }
  record.count("channel_send_errors_total", [
    #("channel", channel),
    #("error", kind),
  ])
  safe_io.println(
    "warn: reply not delivered channel=" <> channel <> " error=" <> kind,
  )
  "send_error"
}

fn await_late_terminal(
  events: process.Subject(port.ChannelStreamEvent),
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  base_reply: port.ChannelReply,
  chat_key: String,
  deadline: Int,
) -> Nil {
  let remaining = deadline - current_timestamp()
  case remaining <= 0 {
    True -> {
      io.println("error: chat lane turn hard timeout key=" <> chat_key)
      Nil
    }
    False ->
      case process.receive(events, within: remaining) {
        Ok(port.StreamComplete(reply)) -> {
          case string.trim(reply.content) {
            "" -> Nil
            _ -> {
              let _ =
                send_fn(
                  port.ChannelReply(
                    ..base_reply,
                    content: reply.content,
                    edit_message_id: None,
                    typing: False,
                  ),
                )
              Nil
            }
          }
        }
        Ok(port.StreamFailure(_)) -> Nil
        Ok(port.StreamUpdate(_)) ->
          await_late_terminal(events, send_fn, base_reply, chat_key, deadline)
        Error(_) -> {
          io.println("error: chat lane turn hard timeout key=" <> chat_key)
          Nil
        }
      }
  }
}

pub fn noop_handler() -> port.ChannelHandler {
  fn(_, _) { Error(port.Ignored("no inbound handler configured")) }
}

// ============================================================================
// Outbound Senders
// ============================================================================

/// Deliver the final stream content within the channel's length limit: the
/// first part edits the placeholder, the remaining parts go out as new
/// messages. Editing a message past the limit is rejected by the channel.
pub fn finish_stream_in_parts(
  reply: port.ChannelReply,
  placeholder_id: String,
  max_length: Int,
  deliver: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
) -> Result(Nil, port.ChannelError) {
  case chunking.split_reply(reply, max_length) {
    [] -> Ok(Nil)
    [first, ..rest] -> {
      let first_result =
        deliver(
          port.ChannelReply(..first, edit_message_id: Some(placeholder_id)),
        )
      case first_result {
        Ok(_) -> send_remaining_parts(rest, deliver, reply)
        Error(error) ->
          case is_message_not_modified(error) {
            True -> send_remaining_parts(rest, deliver, reply)
            False -> Error(error)
          }
      }
    }
  }
}

fn send_remaining_parts(
  parts: List(port.ChannelReply),
  deliver: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  base_reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  case parts {
    [] -> Ok(Nil)
    [part, ..rest] ->
      case deliver(part) {
        Ok(_) -> send_remaining_parts(rest, deliver, base_reply)
        Error(port.RateLimited(retry_after_seconds)) ->
          deliver_rate_limited_part(
            part,
            rest,
            deliver,
            base_reply,
            retry_after_seconds,
            1,
            0,
          )
        Error(error) -> Error(error)
      }
  }
}

fn deliver_rate_limited_part(
  part: port.ChannelReply,
  rest: List(port.ChannelReply),
  deliver: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  base_reply: port.ChannelReply,
  retry_after_seconds: Int,
  attempts: Int,
  waited_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let wait_ms =
    int.min(int.min(retry_after_seconds * 1000, 10_000 - waited_ms), 10_000)
  case wait_ms > 0 {
    True -> process.sleep(wait_ms)
    False -> Nil
  }
  let waited_ms = waited_ms + int.max(wait_ms, 0)
  case deliver(part) {
    Ok(_) -> send_remaining_parts(rest, deliver, base_reply)
    Error(port.RateLimited(next_retry)) ->
      case attempts < 3 {
        True ->
          deliver_rate_limited_part(
            part,
            rest,
            deliver,
            base_reply,
            next_retry,
            attempts + 1,
            waited_ms,
          )
        False -> send_stream_fallback(base_reply, deliver)
      }
    Error(error) -> Error(error)
  }
}

fn send_stream_fallback(
  base_reply: port.ChannelReply,
  deliver: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
) -> Result(Nil, port.ChannelError) {
  deliver(
    port.ChannelReply(
      ..base_reply,
      content: "(Não consegui enviar o restante da resposta.)",
      edit_message_id: None,
      typing: False,
    ),
  )
}

pub fn is_message_not_modified(error: port.ChannelError) -> Bool {
  case error {
    port.SendFailed(reason) ->
      string.contains(string.lowercase(reason), "message is not modified")
    _ -> False
  }
}

pub fn stream_update_fits(channel: String, content: String) -> Bool {
  string.length(content) <= stream_max_length(channel)
}

/// Test seam for split-delivery edge cases.
pub fn finish_stream_in_parts_for_test(
  reply: port.ChannelReply,
  placeholder_id: String,
  max_length: Int,
  deliver: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
) -> Result(Nil, port.ChannelError) {
  finish_stream_in_parts(reply, placeholder_id, max_length, deliver)
}

fn stream_max_length(channel: String) -> Int {
  catalog.get(channel).edit_max_length
}

pub fn record_stream_for_test(
  recorder: process.Subject(OutboundRecord),
  channel: String,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
  keepalive_ms: Int,
  timeout_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let message_id = channel <> "-stream-1"

  case channel_supports_typing(channel) && base_reply.typing {
    True ->
      process.send(
        recorder,
        OutboundRecord(
          channel: channel,
          action: "typing",
          content: "",
          message_id: None,
        ),
      )
    False -> Nil
  }

  process.send(
    recorder,
    OutboundRecord(
      channel: channel,
      action: "send",
      content: "Thinking...",
      message_id: Some(message_id),
    ),
  )

  consume_recorded_stream_events(
    recorder,
    channel,
    events,
    message_id,
    "",
    base_reply.typing,
    timeout_ms,
    keepalive_ms,
  )
}

pub fn send_chunked_replies(
  replies: List(port.ChannelReply),
  send_one: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
) -> Result(Nil, port.ChannelError) {
  case replies {
    [] -> Ok(Nil)
    [reply, ..rest] -> {
      use _ <- result.try(send_one(reply))
      send_chunked_replies(rest, send_one)
    }
  }
}

pub fn record_reply_for_test(
  recorder: process.Subject(OutboundRecord),
  channel: String,
  replies: List(port.ChannelReply),
) -> Result(Nil, port.ChannelError) {
  record_reply_for_test_loop(recorder, channel, replies, 1)
}

fn record_reply_for_test_loop(
  recorder: process.Subject(OutboundRecord),
  channel: String,
  replies: List(port.ChannelReply),
  index: Int,
) -> Result(Nil, port.ChannelError) {
  case replies {
    [] -> Ok(Nil)
    [reply, ..rest] -> {
      let #(action, message_id) = case reply.edit_message_id {
        Some(existing_id) -> #("edit", Some(existing_id))
        None -> #("send", Some(channel <> "-send-" <> int.to_string(index)))
      }

      process.send(
        recorder,
        OutboundRecord(
          channel: channel,
          action: action,
          content: reply.content,
          message_id: message_id,
        ),
      )
      record_reply_for_test_loop(recorder, channel, rest, index + 1)
    }
  }
}

fn consume_recorded_stream_events(
  recorder: process.Subject(OutboundRecord),
  channel: String,
  events: process.Subject(port.ChannelStreamEvent),
  message_id: String,
  last_content: String,
  typing: Bool,
  remaining_ms: Int,
  keepalive_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let wait_ms = stream_wait_ms(remaining_ms, keepalive_ms)

  case process.receive(events, within: wait_ms) {
    Ok(port.StreamUpdate(reply)) ->
      case stream_update_fits(channel, reply.content) {
        True -> {
          process.send(
            recorder,
            OutboundRecord(
              channel: channel,
              action: "edit",
              content: reply.content,
              message_id: Some(message_id),
            ),
          )
          consume_recorded_stream_events(
            recorder,
            channel,
            events,
            message_id,
            reply.content,
            typing,
            remaining_ms,
            keepalive_ms,
          )
        }
        False ->
          consume_recorded_stream_events(
            recorder,
            channel,
            events,
            message_id,
            last_content,
            typing,
            remaining_ms,
            keepalive_ms,
          )
      }
    Ok(port.StreamComplete(reply)) -> {
      case reply.content == last_content {
        True -> Ok(Nil)
        False ->
          finish_stream_in_parts(
            reply,
            message_id,
            stream_max_length(channel),
            fn(part) {
              let #(action, id) = case part.edit_message_id {
                Some(id) -> #("edit", Some(id))
                None -> #("send", None)
              }
              process.send(
                recorder,
                OutboundRecord(
                  channel: channel,
                  action: action,
                  content: part.content,
                  message_id: id,
                ),
              )
              Ok(Nil)
            },
          )
      }
    }
    Ok(port.StreamFailure(error)) -> Error(error)
    Error(_) ->
      case remaining_ms <= wait_ms {
        True -> {
          process.send(
            recorder,
            OutboundRecord(
              channel: channel,
              action: "edit",
              content: "Streaming timed out",
              message_id: Some(message_id),
            ),
          )
          Error(port.SendFailed("stream timed out"))
        }
        False -> {
          case channel_supports_typing(channel) && typing {
            True ->
              process.send(
                recorder,
                OutboundRecord(
                  channel: channel,
                  action: "typing",
                  content: "",
                  message_id: None,
                ),
              )
            False -> Nil
          }

          consume_recorded_stream_events(
            recorder,
            channel,
            events,
            message_id,
            last_content,
            typing,
            remaining_ms - wait_ms,
            keepalive_ms,
          )
        }
      }
  }
}

pub fn normalize_typing_keepalive_ms(interval_ms: Int) -> Int {
  case interval_ms < 1 {
    True -> default_typing_keepalive_ms
    False -> interval_ms
  }
}

pub fn stream_wait_ms(remaining_ms: Int, keepalive_ms: Int) -> Int {
  case remaining_ms < keepalive_ms {
    True -> remaining_ms
    False -> keepalive_ms
  }
}

fn channel_supports_typing(channel: String) -> Bool {
  catalog.get(channel).supports_typing
}
