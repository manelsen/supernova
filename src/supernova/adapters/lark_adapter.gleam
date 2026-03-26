//// Lark Adapter — implements the ChannelPort contract for Lark/Feishu.
////
//// Lark is a messaging platform by ByteDance. Events are received via
//// webhook callbacks and sent via the Open API. This adapter normalizes
//// Lark events to `ChannelMessage` and renders `ChannelReply` back to
//// Lark message format.
////
//// ## Lark Specifics
////
//// - **Open ID:** `ou_xxxxx` format for user identifiers
//// - **Chat ID:** `oc_xxxxx` for group chats, `p2p_xxxxx` for DMs
//// - **Content:** JSON stringified, e.g. `{"text": "hello"}`
//// - **Sender Type:** `user` or `bot` to filter automated messages
//// - **Threading:** Via `parent_id` field in message
////

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import supernova/channel/port
import supernova/channel/session.{type SessionResolver, without_manager}

// ============================================================================
// Public API
// ============================================================================

/// Parse a raw Lark webhook event JSON into a normalized `ChannelMessage`.
/// Returns `Error(port.Ignored(...))` for events that should be filtered.
pub fn parse_event(event_json: String) -> Result(port.ChannelMessage, port.ChannelError) {
  case json.parse(from: event_json, using: lark_event_decoder()) {
    Ok(event) -> normalize_event(event)
    Error(_) -> Error(port.SendFailed("invalid JSON"))
  }
}

/// Build the Lark message payload for sending a reply.
pub fn build_reply_payload(
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  let content = json.object([
    #("text", json.string(reply.content)),
  ])
  
  let payload = case reply.reply_to_id {
    Some(parent_id) -> json.object([
      #("msg_type", json.string("text")),
      #("content", content),
      #("reply_to_message_id", json.string(parent_id)),
    ])
    None -> json.object([
      #("msg_type", json.string("text")),
      #("content", content),
    ])
  }
  
  Ok(json.to_string(payload))
}

/// Resolve the session ID for a Lark message.
pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  "lark:" <> msg.channel_id <> ":" <> msg.user_id
}

/// Create a session resolver for Lark.
pub fn session_resolver() -> SessionResolver {
  without_manager("lark")
}

// ============================================================================
// Internal: Event Decoding
// ============================================================================

fn lark_event_decoder() -> decode.Decoder(LarkEvent) {
  use header <- decode.field("header", lark_header_decoder())
  use event <- decode.field("event", lark_event_body_decoder())
  decode.success(LarkEvent(header: header, event: event))
}

fn lark_header_decoder() -> decode.Decoder(LarkHeader) {
  use event_type <- decode.field("event_type", decode.string)
  decode.success(LarkHeader(event_type: event_type))
}

fn lark_event_body_decoder() -> decode.Decoder(LarkEventBody) {
  use sender <- decode.field("sender", lark_sender_decoder())
  use message <- decode.field("message", lark_message_decoder())
  decode.success(LarkEventBody(sender: sender, message: message))
}

fn lark_sender_decoder() -> decode.Decoder(LarkSender) {
  use sender_id <- decode.field("sender_id", lark_sender_id_decoder())
  use sender_type <- decode.field("sender_type", decode.string)
  decode.success(LarkSender(sender_id: sender_id, sender_type: sender_type))
}

fn lark_sender_id_decoder() -> decode.Decoder(LarkSenderId) {
  use open_id <- decode.field("open_id", decode.string)
  decode.success(LarkSenderId(open_id: open_id))
}

fn lark_message_decoder() -> decode.Decoder(LarkMessage) {
  use message_id <- decode.field("message_id", decode.string)
  use chat_id <- decode.field("chat_id", decode.string)
  use message_type <- decode.field("message_type", decode.string)
  use content <- decode.field("content", decode.string)
  use parent_id <- decode.optional_field("parent_id", None, decode.string |> decode.map(Some))
  decode.success(LarkMessage(
    message_id: message_id,
    chat_id: chat_id,
    message_type: message_type,
    content: content,
    parent_id: parent_id,
  ))
}

// Decoder for extracting text from Lark's content JSON string
fn lark_content_text_decoder() -> decode.Decoder(String) {
  use text <- decode.field("text", decode.string)
  decode.success(text)
}

// ============================================================================
// Internal: Normalization Logic
// ============================================================================

fn normalize_event(event: LarkEvent) -> Result(port.ChannelMessage, port.ChannelError) {
  case event.header.event_type {
    "im.message.receive_v1" -> normalize_message_event(event)
    _ -> Error(port.Ignored("non-message event: " <> event.header.event_type))
  }
}

fn normalize_message_event(event: LarkEvent) -> Result(port.ChannelMessage, port.ChannelError) {
  let body = event.event
  let msg = body.message
  
  // Filter: only handle text messages
  case msg.message_type {
    "text" -> normalize_user_content(body, msg)
    _ -> Error(port.Ignored("unsupported message_type: " <> msg.message_type))
  }
}

fn normalize_user_content(
  body: LarkEventBody,
  msg: LarkMessage,
) -> Result(port.ChannelMessage, port.ChannelError) {
  // Filter: bot senders
  case body.sender.sender_type {
    "bot" -> Error(port.Ignored("bot sender filtered"))
    _ -> {
      // Extract text from the JSON content string
      let text = case json.parse(from: msg.content, using: lark_content_text_decoder()) {
        Ok(t) -> t
        Error(_) -> ""
      }
      
      // Filter: empty content
      case text {
        "" -> Error(port.Ignored("empty content"))
        _ -> Ok(port.ChannelMessage(
          id: msg.message_id,
          channel: "lark",
          channel_id: msg.chat_id,
          user_id: body.sender.sender_id.open_id,
          username: "",
          content: text,
          is_bot: False,
          reply_to_id: msg.parent_id,
        ))
      }
    }
  }
}

// ============================================================================
// Internal Types
// ============================================================================

type LarkEvent {
  LarkEvent(header: LarkHeader, event: LarkEventBody)
}

type LarkHeader {
  LarkHeader(event_type: String)
}

type LarkEventBody {
  LarkEventBody(sender: LarkSender, message: LarkMessage)
}

type LarkSender {
  LarkSender(sender_id: LarkSenderId, sender_type: String)
}

type LarkSenderId {
  LarkSenderId(open_id: String)
}

type LarkMessage {
  LarkMessage(
    message_id: String,
    chat_id: String,
    message_type: String,
    content: String,
    parent_id: Option(String),
  )
}
