//// Matrix runtime: sending and streaming.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import supernova/adapters/matrix_adapter
import supernova/channel/channel_kit
import supernova/channel/port
import supernova/config

pub fn start_matrix_channel(
  matrix_cfg: config.MatrixConfig,
  handler: port.ChannelHandler,
  hooks: channel_kit.StartHooks,
) -> Result(#(port.ChannelAdapter, channel_kit.StreamSendFn), String) {
  case matrix_cfg.homeserver_url, matrix_cfg.token {
    Some(homeserver_url), Some(token) -> {
      let send_fn = matrix_send(homeserver_url, token, hooks)
      let stream_send_fn = matrix_stream_send(homeserver_url, token, hooks)

      hooks.matrix_inbound_events
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
          name: "matrix",
          send: send_fn,
          stop: fn() { Nil },
          stop_ingress: fn() { Nil },
        ),
        stream_send_fn,
      ))
    }
    None, _ -> Error("enabled but no homeserver_url configured")
    _, None -> Error("enabled but no token configured")
  }
}

// ============================================================================
// Inbound Runtime
// ============================================================================

fn matrix_send(
  homeserver_url: String,
  access_token: String,
  hooks: channel_kit.StartHooks,
) -> fn(port.ChannelReply) -> Result(Nil, port.ChannelError) {
  fn(reply: port.ChannelReply) {
    case hooks.outbound_records {
      Some(recorder) ->
        channel_kit.record_reply_for_test(recorder, "matrix", [reply])
      None -> matrix_adapter.send_reply(homeserver_url, access_token, reply)
    }
  }
}

fn matrix_stream_send(
  homeserver_url: String,
  access_token: String,
  hooks: channel_kit.StartHooks,
) -> channel_kit.StreamSendFn {
  fn(
    base_reply: port.ChannelReply,
    events: process.Subject(port.ChannelStreamEvent),
  ) {
    let keepalive_ms =
      channel_kit.normalize_typing_keepalive_ms(hooks.typing_keepalive_ms)
    case hooks.outbound_records {
      Some(recorder) ->
        channel_kit.record_stream_for_test(
          recorder,
          "matrix",
          base_reply,
          events,
          keepalive_ms,
          hooks.stream_timeout_ms,
        )
      None ->
        stream_matrix_reply(
          homeserver_url,
          access_token,
          base_reply,
          events,
          keepalive_ms,
        )
    }
  }
}

fn stream_matrix_reply(
  homeserver_url: String,
  access_token: String,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
  _keepalive_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let placeholder = port.ChannelReply(..base_reply, content: "Thinking...")

  use event_id <- result.try(matrix_adapter.send_reply_with_event_id(
    homeserver_url,
    access_token,
    placeholder,
  ))

  consume_matrix_stream_events(
    homeserver_url,
    access_token,
    events,
    event_id,
    "",
    False,
    channel_kit.stream_timeout_ms,
  )
}

fn consume_matrix_stream_events(
  homeserver_url: String,
  access_token: String,
  events: process.Subject(port.ChannelStreamEvent),
  event_id: String,
  last_content: String,
  uncertain: Bool,
  remaining_ms: Int,
) -> Result(Nil, port.ChannelError) {
  case process.receive(events, within: remaining_ms) {
    Ok(port.StreamUpdate(reply)) -> {
      // `last_content` is what the person sees: it advances only when an
      // edit succeeds, so completion resends after a failed or skipped edit.
      // A failed edit may still have been applied by the homeserver, so the
      // visible content is uncertain until the next successful edit.
      let #(delivered, uncertain) = case
        channel_kit.stream_update_fits("matrix", reply.content)
      {
        True -> {
          let edit_reply =
            port.ChannelReply(..reply, edit_message_id: Some(event_id))
          case
            matrix_adapter.send_reply(homeserver_url, access_token, edit_reply)
          {
            Ok(_) -> #(reply.content, False)
            Error(_) -> #(last_content, True)
          }
        }
        False -> #(last_content, uncertain)
      }
      consume_matrix_stream_events(
        homeserver_url,
        access_token,
        events,
        event_id,
        delivered,
        uncertain,
        remaining_ms,
      )
    }
    Ok(port.StreamComplete(reply)) ->
      case reply.content == last_content && !uncertain {
        True -> Ok(Nil)
        False -> {
          let final_reply =
            port.ChannelReply(..reply, edit_message_id: Some(event_id))
          matrix_adapter.send_reply(homeserver_url, access_token, final_reply)
        }
      }
    Ok(port.StreamFailure(error)) -> Error(error)
    Error(_) -> Error(port.SendFailed("stream timed out"))
  }
}
