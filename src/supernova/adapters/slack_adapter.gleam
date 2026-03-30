//// Slack Adapter — implements the ChannelPort contract for Slack.
////
//// Slack uses the Events API and Interactive Components.
//// This adapter normalizes Slack events to `ChannelMessage`
//// and renders `ChannelReply` back to Slack message format.
////
//// ## Slack Specifics
////
//// - **Channel IDs:** Start with C (channels), D (DMs), G (private groups)
//// - **User IDs:** Start with U
//// - **Bot IDs:** Start with B
//// - **Threading:** Via `thread_ts` field
//// - **Mentions:** @username format
////

import gleam/dynamic/decode
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/channel/chunking
import supernova/channel/port
import supernova/channel/session.{type SessionResolver, without_manager}

// ============================================================================
// Public API
// ============================================================================

pub type ProgressMode {
  NativeStream
  MessageUpdateFallback
}

pub type ProgressSession {
  NativeProgressSession(channel_id: String, stream_ts: String)
  MessageUpdateSession(channel_id: String, message_ts: String)
}

/// Start the Slack adapter with the given config.
/// Returns a `ChannelAdapter` that the core uses to send replies.
pub fn start(
  bot_token: String,
  _signing_secret: String,
  _handler: port.ChannelHandler,
) -> Result(port.ChannelAdapter, String) {
  let send_fn = fn(reply: port.ChannelReply) -> Result(Nil, port.ChannelError) {
    send_reply(bot_token, reply)
  }

  Ok(port.ChannelAdapter(name: "slack", send: send_fn, stop: fn() { Nil }))
}

pub fn send_reply(
  bot_token: String,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  do_send(bot_token, reply)
}

pub fn progress_mode(reply: port.ChannelReply) -> ProgressMode {
  case
    slack_stream_thread_target(reply),
    is_direct_message_channel(reply.channel_id)
  {
    Some(_), True -> NativeStream
    _, _ -> MessageUpdateFallback
  }
}

pub fn build_stream_start_payload(
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  case slack_stream_thread_target(reply) {
    Some(thread_ts) ->
      Ok(
        json.to_string(
          json.object([
            #("channel", json.string(reply.channel_id)),
            #("thread_ts", json.string(thread_ts)),
            #("markdown_text", json.string(slack_progress_placeholder(reply))),
          ]),
        ),
      )
    None ->
      Error(port.SendFailed("Slack streaming requires thread_ts or reply_to_id"))
  }
}

pub fn build_stream_append_payload(
  channel_id channel_id: String,
  stream_ts stream_ts: String,
  markdown_text markdown_text: String,
) -> String {
  json.object([
    #("channel", json.string(channel_id)),
    #("ts", json.string(stream_ts)),
    #("markdown_text", json.string(markdown_text)),
  ])
  |> json.to_string
}

pub fn build_stream_stop_payload(
  channel_id channel_id: String,
  stream_ts stream_ts: String,
  trailing_text trailing_text: String,
) -> String {
  let fields = [
    #("channel", json.string(channel_id)),
    #("ts", json.string(stream_ts)),
  ]

  let fields = case string.is_empty(trailing_text) {
    True -> fields
    False -> [#("markdown_text", json.string(trailing_text)), ..fields]
  }

  json.object(fields) |> json.to_string
}

pub fn start_progress(
  bot_token: String,
  reply: port.ChannelReply,
) -> Result(ProgressSession, port.ChannelError) {
  case progress_mode(reply) {
    NativeStream -> start_native_progress(bot_token, reply)
    MessageUpdateFallback -> start_message_update_progress(bot_token, reply)
  }
}

pub fn append_progress(
  bot_token: String,
  session: ProgressSession,
  content: String,
) -> Result(Nil, port.ChannelError) {
  case session {
    NativeProgressSession(channel_id:, stream_ts:) ->
      case string.is_empty(content) {
        True -> Ok(Nil)
        False ->
          send_ok_only(
            bot_token,
            "https://slack.com/api/chat.appendStream",
            build_stream_append_payload(
              channel_id: channel_id,
              stream_ts: stream_ts,
              markdown_text: content,
            ),
          )
      }
    MessageUpdateSession(channel_id:, message_ts:) ->
      update_message(
        bot_token,
        port.ChannelReply(
          channel_id: channel_id,
          content: content,
          reply_to_id: None,
          thread_id: None,
          typing: False,
          edit_message_id: Some(message_ts),
          interactive: None,
          media: [],
        ),
        message_ts,
      )
  }
}

pub fn finish_progress(
  bot_token: String,
  session: ProgressSession,
  content: String,
) -> Result(Nil, port.ChannelError) {
  case session {
    NativeProgressSession(channel_id:, stream_ts:) ->
      send_ok_only(
        bot_token,
        "https://slack.com/api/chat.stopStream",
        build_stream_stop_payload(
          channel_id: channel_id,
          stream_ts: stream_ts,
          trailing_text: content,
        ),
      )
    MessageUpdateSession(channel_id:, message_ts:) ->
      update_message(
        bot_token,
        port.ChannelReply(
          channel_id: channel_id,
          content: content,
          reply_to_id: None,
          thread_id: None,
          typing: False,
          edit_message_id: Some(message_ts),
          interactive: None,
          media: [],
        ),
        message_ts,
      )
  }
}

/// Parse a raw Slack event JSON into a normalized `ChannelMessage`.
/// Returns `Error(port.Ignored(...))` for events that should be filtered.
pub fn parse_event(
  event_json: String,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case json.parse(event_json, slack_envelope_decoder()) {
    Ok(SlackEventEnvelope(event)) -> normalize_event(event)
    Error(_) ->
      case json.parse(event_json, slack_event_decoder()) {
        Ok(event) -> normalize_event(event)
        Error(_) -> Error(port.SendFailed("invalid JSON"))
      }
  }
}

/// Build the Slack message payload for sending a reply.
pub fn build_reply_payload(
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  build_single_reply_payload(reply)
}

/// Build one or more Slack payloads when a reply exceeds channel limits.
pub fn build_reply_payloads(
  reply: port.ChannelReply,
) -> Result(List(String), port.ChannelError) {
  let chunkable_reply =
    port.ChannelReply(..reply, thread_id: port.thread_target(reply))

  chunking.split_reply(chunkable_reply, chunking.slack_max_length)
  |> build_reply_payloads_loop([])
}

fn build_reply_payloads_loop(
  replies: List(port.ChannelReply),
  acc: List(String),
) -> Result(List(String), port.ChannelError) {
  case replies {
    [] -> Ok(list.reverse(acc))
    [reply, ..rest] ->
      case build_single_reply_payload(reply) {
        Ok(payload) -> build_reply_payloads_loop(rest, [payload, ..acc])
        Error(error) -> Error(error)
      }
  }
}

fn build_single_reply_payload(
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  let blocks = case reply.interactive {
    Some(interactive) -> build_interactive_blocks(interactive)
    None -> []
  }

  let payload = case port.thread_target(reply) {
    Some(thread_ts) ->
      json.object([
        #("channel", json.string(reply.channel_id)),
        #("text", json.string(reply.content)),
        #("thread_ts", json.string(thread_ts)),
        #("blocks", json.array(blocks, fn(block) { block })),
      ])
    None ->
      json.object([
        #("channel", json.string(reply.channel_id)),
        #("text", json.string(reply.content)),
        #("blocks", json.array(blocks, fn(block) { block })),
      ])
  }

  Ok(json.to_string(payload))
}

/// Resolve the session ID for a Slack message.
pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  "slack:" <> msg.channel_id <> ":" <> msg.user_id
}

/// Create a session resolver for Slack.
pub fn session_resolver() -> SessionResolver {
  without_manager("slack")
}

/// Check if a user ID belongs to a bot.
pub fn is_bot_user(user_id: String) -> Bool {
  case user_id {
    "B" <> _ -> True
    _ -> False
  }
}

// ============================================================================
// Internal: Event Decoding
// ============================================================================

fn slack_event_decoder() -> decode.Decoder(SlackEvent) {
  use event_type <- decode.field("type", decode.string)
  use user <- decode.field("user", decode.string)
  use text <- decode.field("text", decode.string)
  use channel <- decode.field("channel", decode.string)
  use ts <- decode.field("ts", decode.string)
  use thread_ts <- decode.optional_field(
    "thread_ts",
    None,
    decode.string |> decode.map(Some),
  )
  use bot_id <- decode.optional_field(
    "bot_id",
    None,
    decode.string |> decode.map(Some),
  )
  use subtype <- decode.optional_field(
    "subtype",
    None,
    decode.string |> decode.map(Some),
  )

  decode.success(SlackEvent(
    event_type: event_type,
    user: user,
    text: text,
    channel: channel,
    ts: ts,
    thread_ts: thread_ts,
    bot_id: bot_id,
    subtype: subtype,
  ))
}

type SlackEvent {
  SlackEvent(
    event_type: String,
    user: String,
    text: String,
    channel: String,
    ts: String,
    thread_ts: Option(String),
    bot_id: Option(String),
    subtype: Option(String),
  )
}

type SlackEnvelope {
  SlackEventEnvelope(SlackEvent)
}

fn slack_envelope_decoder() -> decode.Decoder(SlackEnvelope) {
  decode.field("type", decode.string, fn(envelope_type) {
    case envelope_type {
      "event_callback" ->
        decode.field("event", slack_event_decoder(), fn(event) {
          decode.success(SlackEventEnvelope(event))
        })
      _ ->
        decode.failure(
          SlackEventEnvelope(empty_slack_event()),
          "event_callback",
        )
    }
  })
}

fn empty_slack_event() -> SlackEvent {
  SlackEvent(
    event_type: "",
    user: "",
    text: "",
    channel: "",
    ts: "",
    thread_ts: None,
    bot_id: None,
    subtype: None,
  )
}

// ============================================================================
// Internal: Normalization Logic
// ============================================================================

fn normalize_event(
  event: SlackEvent,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case event.subtype {
    Some("bot_message") -> Error(port.Ignored("bot sender filtered"))
    Some(subtype) -> Error(port.Ignored("unsupported subtype: " <> subtype))
    None ->
      case event.bot_id {
        Some(_) -> Error(port.Ignored("bot sender filtered"))
        None ->
          case is_bot_user(event.user) {
            True -> Error(port.Ignored("bot sender filtered"))
            False -> normalize_user_event(event)
          }
      }
  }
}

fn normalize_user_event(
  event: SlackEvent,
) -> Result(port.ChannelMessage, port.ChannelError) {
  // Filter: ignore empty content
  case string.is_empty(event.text) {
    True -> Error(port.Ignored("empty content"))
    False ->
      Ok(port.ChannelMessage(
        id: event.ts,
        channel: "slack",
        channel_id: event.channel,
        user_id: event.user,
        username: "",
        // Would need to fetch user info
        content: strip_bot_mention(event.text),
        is_bot: False,
        reply_to_id: event.thread_ts,
      ))
  }
}

fn strip_bot_mention(text: String) -> String {
  // Remove <@UXXXXXXXX> mention format
  case string.split_once(text, "<@") {
    Ok(#(before, after)) -> {
      case string.split_once(after, ">") {
        Ok(#(_, rest)) -> before <> rest
        Error(_) -> text
      }
    }
    Error(_) -> text
  }
}

// ============================================================================
// Internal: Interactive Blocks
// ============================================================================

fn build_interactive_blocks(
  interactive: port.ChannelInteractiveReply,
) -> List(json.Json) {
  list.map(interactive.blocks, build_block)
}

fn build_block(block: port.ChannelInteractionBlock) -> json.Json {
  case block {
    port.InteractionText(text) ->
      json.object([
        #("type", json.string("section")),
        #(
          "text",
          json.object([
            #("type", json.string("mrkdwn")),
            #("text", json.string(text)),
          ]),
        ),
      ])
    port.InteractionButtons(buttons) -> build_buttons_block(buttons)
    port.InteractionSelect(action_id:, placeholder:, options:) ->
      build_select_block(action_id, placeholder, options)
  }
}

fn build_buttons_block(buttons: List(port.ChannelButton)) -> json.Json {
  let actions =
    list.map(buttons, fn(btn: port.ChannelButton) {
      let label = port.button_label(btn)
      let action_id = port.button_action_id(btn)
      let fields = [
        #("type", json.string("button")),
        #(
          "text",
          json.object([
            #("type", json.string("plain_text")),
            #("text", json.string(label)),
          ]),
        ),
        #("action_id", json.string(action_id)),
      ]

      let fields = case port.button_style(btn) {
        port.ButtonPrimary -> [#("style", json.string("primary")), ..fields]
        port.ButtonDanger -> [#("style", json.string("danger")), ..fields]
        _ -> fields
      }

      json.object(fields)
    })

  json.object([
    #("type", json.string("actions")),
    #("elements", json.array(actions, fn(action) { action })),
  ])
}

fn build_select_block(
  action_id: String,
  placeholder: Option(String),
  options: List(port.ChannelSelectOption),
) -> json.Json {
  let placeholder_text = placeholder |> option.unwrap("Select an option")
  let option_json =
    list.map(options, fn(opt: port.ChannelSelectOption) {
      let label = port.select_option_label(opt)
      let value = port.select_option_value(opt)

      json.object([
        #(
          "text",
          json.object([
            #("type", json.string("plain_text")),
            #("text", json.string(label)),
          ]),
        ),
        #("value", json.string(value)),
      ])
    })

  json.object([
    #("type", json.string("section")),
    #(
      "text",
      json.object([
        #("type", json.string("mrkdwn")),
        #("text", json.string("_")),
      ]),
    ),
    #(
      "accessory",
      json.object([
        #("type", json.string("static_select")),
        #("action_id", json.string(action_id)),
        #(
          "placeholder",
          json.object([
            #("type", json.string("plain_text")),
            #("text", json.string(placeholder_text)),
          ]),
        ),
        #("options", json.array(option_json, fn(option) { option })),
      ]),
    ),
  ])
}

// ============================================================================
// Internal: Sending
// ============================================================================

fn do_send(
  bot_token: String,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  case build_reply_payloads(reply) {
    Error(error) -> Error(error)
    Ok(payloads) -> send_payloads(bot_token, payloads)
  }
}

fn start_native_progress(
  bot_token: String,
  reply: port.ChannelReply,
) -> Result(ProgressSession, port.ChannelError) {
  use payload <- result.try(build_stream_start_payload(reply))
  use ts <- result.try(send_for_ts(
    bot_token,
    "https://slack.com/api/chat.startStream",
    payload,
  ))
  Ok(NativeProgressSession(channel_id: reply.channel_id, stream_ts: ts))
}

fn start_message_update_progress(
  bot_token: String,
  reply: port.ChannelReply,
) -> Result(ProgressSession, port.ChannelError) {
  let placeholder =
    port.ChannelReply(
      ..reply,
      content: slack_progress_placeholder(reply),
      typing: False,
      edit_message_id: None,
    )

  use ts <- result.try(send_message(bot_token, placeholder))
  Ok(MessageUpdateSession(channel_id: reply.channel_id, message_ts: ts))
}

fn send_payloads(
  bot_token: String,
  payloads: List(String),
) -> Result(Nil, port.ChannelError) {
  case payloads {
    [] -> Ok(Nil)
    [payload, ..rest] -> {
      use _ <- result.try(send_ok_only(
        bot_token,
        "https://slack.com/api/chat.postMessage",
        payload,
      ))
      send_payloads(bot_token, rest)
    }
  }
}

fn send_message(
  bot_token: String,
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  use payload <- result.try(build_single_reply_payload(reply))
  send_for_ts(bot_token, "https://slack.com/api/chat.postMessage", payload)
}

fn update_message(
  bot_token: String,
  reply: port.ChannelReply,
  message_ts: String,
) -> Result(Nil, port.ChannelError) {
  use payload <- result.try(build_update_payload(reply, message_ts))
  send_ok_only(bot_token, "https://slack.com/api/chat.update", payload)
}

fn build_update_payload(
  reply: port.ChannelReply,
  message_ts: String,
) -> Result(String, port.ChannelError) {
  let blocks = case reply.interactive {
    Some(interactive) -> build_interactive_blocks(interactive)
    None -> []
  }

  Ok(
    json.to_string(
      json.object([
        #("channel", json.string(reply.channel_id)),
        #("ts", json.string(message_ts)),
        #("text", json.string(reply.content)),
        #("blocks", json.array(blocks, fn(block) { block })),
      ]),
    ),
  )
}

fn send_ok_only(
  bot_token: String,
  url: String,
  payload: String,
) -> Result(Nil, port.ChannelError) {
  use response <- result.try(send_to_slack(bot_token, url, payload))
  handle_slack_response(response)
}

fn send_for_ts(
  bot_token: String,
  url: String,
  payload: String,
) -> Result(String, port.ChannelError) {
  use response <- result.try(send_to_slack(bot_token, url, payload))
  handle_slack_ts_response(response)
}

fn send_to_slack(
  bot_token: String,
  url: String,
  payload: String,
) -> Result(Response(String), port.ChannelError) {
  // Build HTTP POST request using pipe operator
  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_header("Authorization", "Bearer " <> bot_token)
    |> request.set_header("Content-Type", "application/json")

  // Set the URL and body
  let req_with_url = request.set_host(req, url)
  let req_with_body = request.set_body(req_with_url, payload)

  // Send the request
  case hackney.send(req_with_body) {
    Ok(response) -> Ok(response)
    Error(hackney.InvalidUtf8Response) ->
      Error(port.SendFailed("Invalid UTF-8 response from Slack"))
    Error(hackney.Other(reason)) ->
      Error(port.SendFailed("HTTP error: " <> string.inspect(reason)))
  }
}

/// Handle HTTP response from Slack API.
fn handle_slack_response(
  response: Response(String),
) -> Result(Nil, port.ChannelError) {
  use _ <- result.try(slack_response_ts(response, False))
  Ok(Nil)
}

fn handle_slack_ts_response(
  response: Response(String),
) -> Result(String, port.ChannelError) {
  slack_response_ts(response, True)
}

fn slack_response_ts(
  response: Response(String),
  require_ts: Bool,
) -> Result(String, port.ChannelError) {
  case response.status {
    200 -> {
      let decoder = {
        use ok <- decode.field("ok", decode.bool)
        use ts <- decode.optional_field(
          "ts",
          None,
          decode.string |> decode.map(Some),
        )
        use error <- decode.optional_field(
          "error",
          None,
          decode.string |> decode.map(Some),
        )
        decode.success(#(ok, ts, error))
      }

      case json.parse(from: response.body, using: decoder) {
        Ok(#(True, Some(ts), _)) -> Ok(ts)
        Ok(#(True, None, _)) ->
          case require_ts {
            True -> Error(port.SendFailed("Slack response missing ts"))
            False -> Ok("")
          }
        Ok(#(False, _, Some(error))) ->
          Error(port.SendFailed("Slack API error: " <> error))
        Ok(#(False, _, None)) ->
          Error(port.SendFailed("Slack API error: Unknown error"))
        Error(_) -> Error(port.SendFailed("Invalid Slack response"))
      }
    }
    401 -> Error(port.SendFailed("Unauthorized - check bot token"))
    429 -> {
      let retry_after = parse_slack_retry_after(response.body)
      Error(port.RateLimited(retry_after_seconds: retry_after))
    }
    status -> Error(port.SendFailed("Slack error: " <> int.to_string(status)))
  }
}

/// Parse retry_after from rate limit response.
fn parse_slack_retry_after(body: String) -> Int {
  let decoder = {
    use value <- decode.field("retry_after", decode.int)
    decode.success(value)
  }
  case json.parse(from: body, using: decoder) {
    Ok(value) -> value
    Error(_) -> 30
  }
}

fn slack_stream_thread_target(reply: port.ChannelReply) -> Option(String) {
  port.thread_target(reply)
}

fn slack_progress_placeholder(reply: port.ChannelReply) -> String {
  case string.is_empty(reply.content) {
    True -> "Thinking..."
    False -> reply.content
  }
}

fn is_direct_message_channel(channel_id: String) -> Bool {
  case channel_id {
    "D" <> _ -> True
    _ -> False
  }
}
