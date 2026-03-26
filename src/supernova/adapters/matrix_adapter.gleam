//// Matrix Adapter — implements the ChannelPort contract for Matrix.
////
//// Matrix is a federated, E2E-encrypted messaging protocol.
//// Events are received via the Client-Server API (v1.17) and sent via
//// the same API. This adapter normalizes Matrix events to `ChannelMessage`
//// and renders `ChannelReply` back to Matrix message format.
////
//// ## Matrix Specifics
////
//// - **Room IDs:** `!roomid:homeserver.org` format
//// - **User IDs:** `@user:homeserver.org` format (MXIDs)
//// - **Threading:** Via `m.relates_to` with `rel_type: m.thread`
//// - **Content types:** `m.text`, `m.notice`, `m.emote`, `m.file`, etc.
//// - **HTML:** `format: org.matrix.custom.html` with `formatted_body`
////

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port
import supernova/channel/session.{type SessionResolver, without_manager}

// ============================================================================
// Public API
// ============================================================================

/// Start the Matrix adapter with the given homeserver config.
/// Returns a `ChannelAdapter` that the core uses to send replies.
pub fn start(
  homeserver_url: String,
  access_token: String,
  _handler: port.ChannelHandler,
) -> Result(port.ChannelAdapter, String) {
  let send_fn = fn(reply: port.ChannelReply) -> Result(Nil, port.ChannelError) {
    do_send(homeserver_url, access_token, reply)
  }

  Ok(port.ChannelAdapter(
    name: "matrix",
    send: send_fn,
  ))
}

/// Parse a raw Matrix event JSON into a normalized `ChannelMessage`.
/// Returns `Error(port.Ignored(...))` for events that should be filtered.
pub fn parse_event(event_json: String) -> Result(port.ChannelMessage, port.ChannelError) {
  case json.parse(event_json, matrix_event_decoder()) {
    Ok(event) -> normalize_event(event)
    Error(_) -> Error(port.SendFailed("invalid JSON"))
  }
}

/// Build the Matrix message payload for sending a reply.
/// Returns JSON string suitable for PUT /rooms/{roomId}/send/m.room.message/{txnId}.
pub fn build_send_payload(
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  let content = reply.content
  let body = case reply.reply_to_id {
    Some(parent_id) -> json.object([
      #("msgtype", json.string("m.text")),
      #("body", json.string(content)),
      #("m.relates_to", json.object([
        #("rel_type", json.string("m.thread")),
        #("event_id", json.string(parent_id)),
      ])),
    ])
    None -> json.object([
      #("msgtype", json.string("m.text")),
      #("body", json.string(content)),
    ])
  }

  Ok(json.to_string(body))
}

/// Resolve the session ID for a Matrix message.
/// Format: `matrix:{room_id}:{user_id}`
pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  "matrix:" <> msg.channel_id <> ":" <> msg.user_id
}

/// Create a session resolver for Matrix.
pub fn session_resolver() -> SessionResolver {
  without_manager("matrix")
}

/// Check if a sender MXID belongs to a bot user.
/// Used internally and exposed for testing.
pub fn is_bot_sender(sender: String) -> Bool {
  // Heuristic: Matrix bots typically have :bot in their MXID
  // e.g., @bot:matrix.example.org or @mybot:homeserver.org
  // Simple check: does sender contain ":bot"?
  case sender {
    "@bot:" <> _ -> True
    _ -> string.contains(sender, ":bot")
  }
}

// ============================================================================
// Internal: Event Decoding
// ============================================================================

fn matrix_event_decoder() -> decode.Decoder(MatrixEvent) {
  use event_type <- decode.field("type", decode.string)
  use sender <- decode.field("sender", decode.string)
  use room_id <- decode.field("room_id", decode.string)
  use event_id <- decode.field("event_id", decode.string)
  use content <- decode.field("content", matrix_content_decoder())
  use relates_to <- decode.optional_field("m.relates_to", None, decode.optional(matrix_relation_decoder()))
  use unsigned <- decode.optional_field("unsigned", None, decode.optional(matrix_unsigned_decoder()))

  decode.success(MatrixEvent(
    event_type: event_type,
    sender: sender,
    room_id: room_id,
    event_id: event_id,
    content: content,
    relates_to: relates_to,
    unsigned: unsigned,
  ))
}

type MatrixEvent {
  MatrixEvent(
    event_type: String,
    sender: String,
    room_id: String,
    event_id: String,
    content: MatrixContent,
    relates_to: Option(MatrixRelation),
    unsigned: Option(MatrixUnsigned),
  )
}

type MatrixContent {
  MatrixContent(
    msgtype: String,
    body: String,
    format: Option(String),
    formatted_body: Option(String),
  )
}

type MatrixUnsigned {
  MatrixUnsigned(displayname: Option(String))
}

type MatrixRelation {
  MatrixRelation(rel_type: String, event_id: String)
}

fn matrix_content_decoder() -> decode.Decoder(MatrixContent) {
  use msgtype <- decode.field("msgtype", decode.string)
  use body <- decode.field("body", decode.string)
  use format <- decode.optional_field("format", None, decode.string |> decode.map(Some))
  use formatted_body <- decode.optional_field("formatted_body", None, decode.string |> decode.map(Some))

  decode.success(MatrixContent(
    msgtype: msgtype,
    body: body,
    format: format,
    formatted_body: formatted_body,
  ))
}

fn matrix_unsigned_decoder() -> decode.Decoder(MatrixUnsigned) {
  use displayname <- decode.optional_field("displayname", None, decode.string |> decode.map(Some))

  decode.success(MatrixUnsigned(displayname: displayname))
}

fn matrix_relation_decoder() -> decode.Decoder(MatrixRelation) {
  use rel_type <- decode.field("rel_type", decode.string)
  use event_id <- decode.field("event_id", decode.string)
  decode.success(MatrixRelation(rel_type: rel_type, event_id: event_id))
}

// ============================================================================
// Internal: Normalization Logic
// ============================================================================

fn normalize_event(event: MatrixEvent) -> Result(port.ChannelMessage, port.ChannelError) {
  // Filter: only handle m.room.message events
  case event.event_type {
    "m.room.message" -> normalize_message_event(event)
    _ -> Error(port.Ignored("non-message event: " <> event.event_type))
  }
}

fn normalize_message_event(event: MatrixEvent) -> Result(port.ChannelMessage, port.ChannelError) {
  // Filter: only handle text and emote types
  case event.content.msgtype {
    "m.text" | "m.emote" | "m.notice" -> normalize_text_content(event)
    _ -> Error(port.Ignored("unsupported msgtype: " <> event.content.msgtype))
  }
}

fn normalize_text_content(event: MatrixEvent) -> Result(port.ChannelMessage, port.ChannelError) {
  let content = event.content

  // Filter: strip HTML if present, use plain body
  let text = case content.formatted_body, content.format {
    Some(html), Some("org.matrix.custom.html") -> strip_html(html)
    _, _ -> content.body
  }

  // Filter: empty content
  case string.is_empty(text) {
    True -> Error(port.Ignored("empty content"))
    False -> normalize_user_content(event, text)
  }
}

fn normalize_user_content(event: MatrixEvent, text: String) -> Result(port.ChannelMessage, port.ChannelError) {
  // Check if sender is a bot - filter bots out
  case is_bot_sender(event.sender) {
    True -> Error(port.Ignored("bot sender filtered"))
    False -> {
      // Extract reply_to_id from m.relates_to if it's a thread
      let reply_to = case event.relates_to {
        Some(rel) if rel.rel_type == "m.thread" -> Some(rel.event_id)
        _ -> None
      }

      // Get display name from unsigned if available
      let display_name = case event.unsigned {
        Some(u) -> option.unwrap(u.displayname, "")
        None -> ""
      }

      Ok(port.ChannelMessage(
        id: event.event_id,
        channel: "matrix",
        channel_id: event.room_id,
        user_id: event.sender,
        username: display_name,
        content: text,
        is_bot: False,
        reply_to_id: reply_to,
      ))
    }
  }
}

// ============================================================================
// Internal: HTML Stripping
// ============================================================================

fn strip_html(html: String) -> String {
  // Simple HTML tag stripping - remove <tags> keeping content
  html
  |> string.replace("<br>", " ")
  |> string.replace("<br/>", " ")
  |> string.replace("<br />", " ")
  |> string.replace("<p>", "")
  |> string.replace("</p>", " ")
  |> string.replace("<strong>", "")
  |> string.replace("</strong>", "")
  |> string.replace("<em>", "")
  |> string.replace("</em>", "")
  |> string.replace("<b>", "")
  |> string.replace("</b>", "")
  |> string.replace("<i>", "")
  |> string.replace("</i>", "")
  |> string.replace("<code>", "")
  |> string.replace("</code>", "")
  |> string.replace("<pre>", "")
  |> string.replace("</pre>", "")
  |> string.replace("<a href=\"", "")
  |> string.replace("\">", " ")
  |> string.replace("</a>", "")
  |> strip_remaining_tags
}

fn strip_remaining_tags(s: String) -> String {
  case string.split(s, "<") {
    [first] -> first
    parts -> {
      let cleaned = list.map(parts, fn(part) {
        case string.split(part, ">") {
          [_, rest] -> rest
          _ -> ""
        }
      })
      string.join(cleaned, "")
    }
  }
}

// ============================================================================
// Internal: Sending
// ============================================================================

fn do_send(
  _homeserver_url: String,
  _access_token: String,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  // Build the message payload
  case build_send_payload(reply) {
    Error(e) -> Error(e)
    Ok(_payload) -> {
      // TODO: Implement actual HTTP PUT to homeserver
      // PUT /_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}
      // Headers: Authorization: Bearer {access_token}
      // Body: {payload}
      //
      // For now, return NotConnected to indicate this needs implementation
      Error(port.NotConnected)
    }
  }
}
