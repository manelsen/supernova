//// Slack runtime: sending and native streaming.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import supernova/adapters/slack_adapter
import supernova/channel/channel_kit
import supernova/channel/port
import supernova/config

pub fn start_slack_channel(
  slack_cfg: config.SlackConfig,
  handler: port.ChannelHandler,
  hooks: channel_kit.StartHooks,
) -> Result(#(port.ChannelAdapter, channel_kit.StreamSendFn), String) {
  case slack_cfg.token {
    Some(token) -> {
      let send_fn = slack_send(token, hooks)
      let stream_send_fn = slack_stream_send(token, hooks)

      hooks.slack_inbound_events
      |> list.each(fn(inbound) {
        channel_kit.dispatch_inbound(
          handler,
          send_fn,
          stream_send_fn,
          inbound,
          hooks.registry_id,
          hooks.turn_hard_timeout_ms,
        )
      })

      Ok(#(
        port.ChannelAdapter(
          name: "slack",
          send: send_fn,
          stop: fn() { Nil },
          stop_ingress: fn() { Nil },
        ),
        stream_send_fn,
      ))
    }
    None -> Error("enabled but no token configured")
  }
}

fn slack_send(
  bot_token: String,
  hooks: channel_kit.StartHooks,
) -> fn(port.ChannelReply) -> Result(Nil, port.ChannelError) {
  fn(reply: port.ChannelReply) {
    case hooks.outbound_records {
      Some(recorder) ->
        channel_kit.record_reply_for_test(recorder, "slack", [reply])
      None -> slack_adapter.send_reply(bot_token, reply)
    }
  }
}

fn slack_stream_send(
  bot_token: String,
  hooks: channel_kit.StartHooks,
) -> channel_kit.StreamSendFn {
  fn(
    base_reply: port.ChannelReply,
    events: process.Subject(port.ChannelStreamEvent),
  ) {
    case hooks.outbound_records {
      Some(recorder) ->
        record_slack_stream_for_test(recorder, base_reply, events)
      None -> stream_slack_reply(bot_token, base_reply, events)
    }
  }
}

fn stream_slack_reply(
  bot_token: String,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
) -> Result(Nil, port.ChannelError) {
  use session <- result.try(slack_adapter.start_progress(bot_token, base_reply))
  consume_slack_stream_events(
    bot_token,
    session,
    events,
    "",
    channel_kit.stream_timeout_ms,
  )
}

fn consume_slack_stream_events(
  bot_token: String,
  session: slack_adapter.ProgressSession,
  events: process.Subject(port.ChannelStreamEvent),
  last_content: String,
  remaining_ms: Int,
) -> Result(Nil, port.ChannelError) {
  case process.receive(events, within: remaining_ms) {
    Ok(port.StreamUpdate(reply)) -> {
      let next_content =
        slack_progress_content_delta(session, reply.content, last_content)
      use _ <- result.try(slack_adapter.append_progress(
        bot_token,
        session,
        next_content,
      ))
      consume_slack_stream_events(
        bot_token,
        session,
        events,
        reply.content,
        remaining_ms,
      )
    }
    Ok(port.StreamComplete(reply)) -> {
      let final_content =
        slack_progress_content_delta(session, reply.content, last_content)
      slack_adapter.finish_progress(bot_token, session, final_content)
    }
    Ok(port.StreamFailure(error)) -> {
      let _ =
        slack_adapter.finish_progress(
          bot_token,
          session,
          slack_stream_failure_text(error),
        )
      Error(error)
    }
    Error(_) -> {
      let _ =
        slack_adapter.finish_progress(bot_token, session, "Streaming timed out")
      Error(port.SendFailed("stream timed out"))
    }
  }
}

fn record_slack_stream_for_test(
  recorder: process.Subject(channel_kit.OutboundRecord),
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
) -> Result(Nil, port.ChannelError) {
  case slack_adapter.progress_mode(base_reply) {
    slack_adapter.NativeStream -> {
      let message_id = "slack-stream-1"
      process.send(
        recorder,
        channel_kit.OutboundRecord(
          channel: "slack",
          action: "progress_start",
          content: "Thinking...",
          message_id: Some(message_id),
        ),
      )

      consume_recorded_slack_native_stream_events(
        recorder,
        events,
        message_id,
        "",
        channel_kit.stream_timeout_ms,
      )
    }
    slack_adapter.MessageUpdateFallback ->
      channel_kit.record_stream_for_test(
        recorder,
        "slack",
        base_reply,
        events,
        channel_kit.stream_timeout_ms,
        channel_kit.stream_timeout_ms,
      )
  }
}

fn consume_recorded_slack_native_stream_events(
  recorder: process.Subject(channel_kit.OutboundRecord),
  events: process.Subject(port.ChannelStreamEvent),
  message_id: String,
  last_content: String,
  remaining_ms: Int,
) -> Result(Nil, port.ChannelError) {
  case process.receive(events, within: remaining_ms) {
    Ok(port.StreamUpdate(reply)) -> {
      process.send(
        recorder,
        channel_kit.OutboundRecord(
          channel: "slack",
          action: "progress_append",
          content: slack_progress_content_delta(
            slack_adapter.NativeProgressSession(channel_id: "", stream_ts: ""),
            reply.content,
            last_content,
          ),
          message_id: Some(message_id),
        ),
      )
      consume_recorded_slack_native_stream_events(
        recorder,
        events,
        message_id,
        reply.content,
        remaining_ms,
      )
    }
    Ok(port.StreamComplete(reply)) -> {
      process.send(
        recorder,
        channel_kit.OutboundRecord(
          channel: "slack",
          action: "progress_stop",
          content: reply.content,
          message_id: Some(message_id),
        ),
      )
      Ok(Nil)
    }
    Ok(port.StreamFailure(error)) -> Error(error)
    Error(_) -> Error(port.SendFailed("stream timed out"))
  }
}

fn slack_progress_content_delta(
  session: slack_adapter.ProgressSession,
  content: String,
  previous_content: String,
) -> String {
  case session {
    slack_adapter.NativeProgressSession(_, _) ->
      case string.starts_with(content, previous_content) {
        True -> string.drop_start(content, string.length(previous_content))
        False -> content
      }
    slack_adapter.MessageUpdateSession(_, _) -> content
  }
}

fn slack_stream_failure_text(error: port.ChannelError) -> String {
  case error {
    port.SendFailed(reason) -> "Streaming failed: " <> reason
    port.NotConnected -> "Streaming failed: not connected"
    port.RateLimited(_) -> "Streaming failed: rate limited"
    port.Ignored(reason) -> "Streaming failed: " <> reason
    port.UnsupportedInteraction(reason) -> "Streaming failed: " <> reason
  }
}
