//// Google Chat Adapter — implements the ChannelPort contract for Google Chat.
//// Google Chat uses incoming webhooks for receiving messages and the API for sending.
////
//// ## Google Chat Specifics
////
//// - **Space Names:** Format: spaces/{space_id}
//// - **Message Names:** Format: spaces/{space_id}/messages/{message_id}
//// - **Threading:** Via thread.replyTo field
////

import gleam/dynamic/decode
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port
import supernova/channel/session.{type SessionResolver, without_manager}

// ============================================================================
// Public API
// ============================================================================

/// Start the Google Chat adapter with the given webhook URL.
/// Returns a `ChannelAdapter` that the core uses to send replies.
pub fn start(
  webhook_url: String,
  _handler: port.ChannelHandler,
) -> Result(port.ChannelAdapter, String) {
  let send_fn = fn(reply: port.ChannelReply) -> Result(Nil, port.ChannelError) {
    do_send(webhook_url, reply)
  }
  Ok(
    port.ChannelAdapter(
      name: "google_chat",
      send: send_fn,
      stop: fn() { Nil },
      stop_ingress: fn() { Nil },
    ),
  )
}

/// Parse a raw Google Chat event JSON into a normalized `ChannelMessage`.
pub fn parse_event(
  event_json: String,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case json.parse(event_json, google_chat_event_decoder()) {
    Ok(event) -> normalize_event(event)
    Error(_) -> Error(port.SendFailed("invalid JSON"))
  }
}

/// Build the Google Chat message payload for sending a reply.
pub fn build_reply_payload(
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  let payload = case port.thread_target(reply) {
    Some(parent_message) ->
      json.object([
        #("text", json.string(reply.content)),
        #(
          "thread",
          json.object([#("replyToMessage", json.string(parent_message))]),
        ),
      ])
    None ->
      json.object([
        #("text", json.string(reply.content)),
      ])
  }

  Ok(json.to_string(payload))
}

/// Resolve the session ID for a Google Chat message.
pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  "google_chat:" <> msg.channel_id <> ":" <> msg.user_id
}

/// Create a session resolver for Google Chat.
pub fn session_resolver() -> SessionResolver {
  without_manager("google_chat")
}

type GoogleChatEvent {
  GoogleChatEvent(
    event_type: String,
    space_name: String,
    message_name: String,
    text: Option(String),
    sender_name: String,
    sender_display_name: Option(String),
    sender_type: Option(String),
    reply_to_message: Option(String),
  )
}

fn google_chat_event_decoder() -> decode.Decoder(GoogleChatEvent) {
  use event_type <- decode.field("type", decode.string)
  use space_name <- decode.field("space", google_chat_space_decoder())
  use message <- decode.field("message", google_chat_message_decoder())
  decode.success(GoogleChatEvent(
    event_type: event_type,
    space_name: space_name,
    message_name: message.name,
    text: message.text,
    sender_name: message.sender_name,
    sender_display_name: message.sender_display_name,
    sender_type: message.sender_type,
    reply_to_message: message.reply_to_message,
  ))
}

type GoogleChatMessagePayload {
  GoogleChatMessagePayload(
    name: String,
    text: Option(String),
    sender_name: String,
    sender_display_name: Option(String),
    sender_type: Option(String),
    reply_to_message: Option(String),
  )
}

fn google_chat_space_decoder() -> decode.Decoder(String) {
  decode.field("name", decode.string, fn(name) { decode.success(name) })
}

fn google_chat_message_decoder() -> decode.Decoder(GoogleChatMessagePayload) {
  use name <- decode.field("name", decode.string)
  use text <- decode.optional_field(
    "text",
    None,
    decode.string |> decode.map(Some),
  )
  use sender <- decode.field("sender", google_chat_sender_decoder())
  use thread <- decode.optional_field(
    "thread",
    None,
    google_chat_thread_decoder() |> decode.map(Some),
  )
  decode.success(GoogleChatMessagePayload(
    name: name,
    text: text,
    sender_name: sender.0,
    sender_display_name: sender.1,
    sender_type: sender.2,
    reply_to_message: thread,
  ))
}

fn google_chat_sender_decoder() -> decode.Decoder(
  #(String, Option(String), Option(String)),
) {
  use name <- decode.field("name", decode.string)
  use display_name <- decode.optional_field(
    "displayName",
    None,
    decode.string |> decode.map(Some),
  )
  use sender_type <- decode.optional_field(
    "type",
    None,
    decode.string |> decode.map(Some),
  )
  decode.success(#(name, display_name, sender_type))
}

fn google_chat_thread_decoder() -> decode.Decoder(String) {
  decode.field(
    "replyToMessage",
    decode.one_of(decode.string, or: [
      decode.field("name", decode.string, fn(name) { decode.success(name) }),
    ]),
    fn(reply_to_message) { decode.success(reply_to_message) },
  )
}

fn normalize_event(
  event: GoogleChatEvent,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case event.event_type {
    "MESSAGE" -> normalize_message_event(event)
    _ -> Error(port.Ignored("non-message event"))
  }
}

fn normalize_message_event(
  event: GoogleChatEvent,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case event.sender_type {
    Some("BOT") -> Error(port.Ignored("bot sender filtered"))
    _ ->
      case event.text {
        Some(text) ->
          case string.length(text) {
            0 -> Error(port.Ignored("empty content"))
            _ ->
              Ok(port.ChannelMessage(
                id: event.message_name,
                channel: "google_chat",
                channel_id: event.space_name,
                user_id: event.sender_name,
                username: case event.sender_display_name {
                  Some(display_name) -> display_name
                  None -> ""
                },
                content: text,
                is_bot: False,
                reply_to_id: event.reply_to_message,
              ))
          }
        None -> Error(port.Ignored("empty content"))
      }
  }
}

// ============================================================================
// Internal: Sending
// ============================================================================

fn do_send(
  webhook_url: String,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  // Build the message payload
  case build_reply_payload(reply) {
    Error(e) -> Error(e)
    Ok(payload) -> send_to_google_chat(webhook_url, payload)
  }
}

fn send_to_google_chat(
  webhook_url: String,
  payload: String,
) -> Result(Nil, port.ChannelError) {
  case request.to(webhook_url) {
    Error(_) -> Error(port.SendFailed("invalid webhook URL"))
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Post)
        |> request.set_header("Content-Type", "application/json")
        |> request.set_body(payload)

      case hackney.send(req) {
        Ok(response) -> handle_google_chat_response(response)
        Error(hackney.InvalidUtf8Response) ->
          Error(port.SendFailed("Invalid UTF-8 response from Google Chat"))
        Error(hackney.Other(reason)) ->
          Error(port.SendFailed("HTTP error: " <> string.inspect(reason)))
      }
    }
  }
}

/// Handle HTTP response from Google Chat webhook.
fn handle_google_chat_response(
  response: Response(String),
) -> Result(Nil, port.ChannelError) {
  case response.status {
    200 -> Ok(Nil)
    400 -> Error(port.SendFailed("Bad request - invalid payload"))
    401 | 403 -> Error(port.SendFailed("Unauthorized - check webhook URL"))
    404 -> Error(port.SendFailed("Webhook not found"))
    429 -> {
      // Google Chat doesn't typically return retry_after
      Error(port.RateLimited(retry_after_seconds: 30))
    }
    status ->
      Error(port.SendFailed("Google Chat error: " <> int.to_string(status)))
  }
}
