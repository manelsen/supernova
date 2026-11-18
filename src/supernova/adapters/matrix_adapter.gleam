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
import gleam/erlang/reference
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
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

  Ok(
    port.ChannelAdapter(
      name: "matrix",
      send: send_fn,
      stop: fn() { Nil },
      stop_ingress: fn() { Nil },
    ),
  )
}

/// Send a reply to a Matrix room.
pub fn send_reply(
  homeserver_url: String,
  access_token: String,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  do_send(homeserver_url, access_token, reply)
}

/// Send a reply and return the Matrix event_id for later edits.
pub fn send_reply_with_event_id(
  homeserver_url: String,
  access_token: String,
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  do_send_and_get_event_id(homeserver_url, access_token, reply)
}

/// Parse a raw Matrix event JSON into a normalized `ChannelMessage`.
/// Returns `Error(port.Ignored(...))` for events that should be filtered.
pub fn parse_event(
  event_json: String,
) -> Result(port.ChannelMessage, port.ChannelError) {
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
  let body = case reply.edit_message_id {
    Some(message_id) ->
      build_edit_content(reply.content, port.thread_target(reply), message_id)
    None -> build_message_content(reply.content, port.thread_target(reply))
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
  use relates_to <- decode.optional_field(
    "m.relates_to",
    None,
    decode.optional(matrix_relation_decoder()),
  )
  use unsigned <- decode.optional_field(
    "unsigned",
    None,
    decode.optional(matrix_unsigned_decoder()),
  )
  use redacts <- decode.optional_field(
    "redacts",
    None,
    decode.optional(decode.string),
  )

  decode.success(MatrixEvent(
    event_type: event_type,
    sender: sender,
    room_id: room_id,
    event_id: event_id,
    content: content,
    relates_to: relates_to,
    unsigned: unsigned,
    redacts: redacts,
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
    redacts: Option(String),
  )
}

type MatrixContent {
  MatrixContent(
    msgtype: String,
    body: String,
    format: Option(String),
    formatted_body: Option(String),
    relates_to: Option(MatrixRelation),
    new_content: Option(MatrixRenderedContent),
  )
}

type MatrixRenderedContent {
  MatrixRenderedContent(
    msgtype: String,
    body: String,
    format: Option(String),
    formatted_body: Option(String),
    relates_to: Option(MatrixRelation),
  )
}

type MatrixUnsigned {
  MatrixUnsigned(displayname: Option(String))
}

type MatrixRelation {
  MatrixRelation(rel_type: String, event_id: String)
}

fn matrix_content_decoder() -> decode.Decoder(MatrixContent) {
  use msgtype <- decode.optional_field("msgtype", "", decode.string)
  use body <- decode.optional_field("body", "", decode.string)
  use format <- decode.optional_field(
    "format",
    None,
    decode.string |> decode.map(Some),
  )
  use formatted_body <- decode.optional_field(
    "formatted_body",
    None,
    decode.string |> decode.map(Some),
  )
  use relates_to <- decode.optional_field(
    "m.relates_to",
    None,
    decode.optional(matrix_relation_decoder()),
  )
  use new_content <- decode.optional_field(
    "m.new_content",
    None,
    decode.optional(matrix_rendered_content_decoder()),
  )

  decode.success(MatrixContent(
    msgtype: msgtype,
    body: body,
    format: format,
    formatted_body: formatted_body,
    relates_to: relates_to,
    new_content: new_content,
  ))
}

fn matrix_rendered_content_decoder() -> decode.Decoder(MatrixRenderedContent) {
  use msgtype <- decode.optional_field("msgtype", "", decode.string)
  use body <- decode.optional_field("body", "", decode.string)
  use format <- decode.optional_field(
    "format",
    None,
    decode.string |> decode.map(Some),
  )
  use formatted_body <- decode.optional_field(
    "formatted_body",
    None,
    decode.string |> decode.map(Some),
  )
  use relates_to <- decode.optional_field(
    "m.relates_to",
    None,
    decode.optional(matrix_relation_decoder()),
  )

  decode.success(MatrixRenderedContent(
    msgtype: msgtype,
    body: body,
    format: format,
    formatted_body: formatted_body,
    relates_to: relates_to,
  ))
}

fn matrix_unsigned_decoder() -> decode.Decoder(MatrixUnsigned) {
  use displayname <- decode.optional_field(
    "displayname",
    None,
    decode.string |> decode.map(Some),
  )

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

fn normalize_event(
  event: MatrixEvent,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case event.event_type {
    "m.room.message" -> normalize_message_event(event)
    "m.room.redaction" -> normalize_redaction_event(event)
    _ -> Error(port.Ignored("non-message event: " <> event.event_type))
  }
}

fn normalize_redaction_event(
  event: MatrixEvent,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case event.redacts {
    Some(event_id) -> Error(port.Ignored("redaction event: " <> event_id))
    None -> Error(port.Ignored("redaction event"))
  }
}

fn normalize_message_event(
  event: MatrixEvent,
) -> Result(port.ChannelMessage, port.ChannelError) {
  let content = effective_content(event.content)

  case content.msgtype {
    "m.text" | "m.emote" | "m.notice" -> normalize_text_content(event)
    _ -> Error(port.Ignored("unsupported msgtype: " <> content.msgtype))
  }
}

fn normalize_text_content(
  event: MatrixEvent,
) -> Result(port.ChannelMessage, port.ChannelError) {
  let content = effective_content(event.content)

  let text = case content.formatted_body, content.format {
    Some(html), Some("org.matrix.custom.html") -> strip_html(html)
    _, _ -> content.body
  }

  case string.is_empty(text) {
    True -> Error(port.Ignored("empty content"))
    False -> normalize_user_content(event, content, text)
  }
}

fn normalize_user_content(
  event: MatrixEvent,
  content: MatrixRenderedContent,
  text: String,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case is_bot_sender(event.sender) {
    True -> Error(port.Ignored("bot sender filtered"))
    False -> {
      let reply_to =
        resolve_thread_relation(content.relates_to, event.relates_to)

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

fn effective_content(content: MatrixContent) -> MatrixRenderedContent {
  case content.relates_to, content.new_content {
    Some(rel), Some(new_content) if rel.rel_type == "m.replace" -> new_content
    _, _ ->
      MatrixRenderedContent(
        msgtype: content.msgtype,
        body: content.body,
        format: content.format,
        formatted_body: content.formatted_body,
        relates_to: content.relates_to,
      )
  }
}

fn resolve_thread_relation(
  content_relation: Option(MatrixRelation),
  event_relation: Option(MatrixRelation),
) -> Option(String) {
  case content_relation {
    Some(rel) if rel.rel_type == "m.thread" -> Some(rel.event_id)
    _ ->
      case event_relation {
        Some(rel) if rel.rel_type == "m.thread" -> Some(rel.event_id)
        _ -> None
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
      let cleaned =
        list.map(parts, fn(part) {
          case string.split(part, ">") {
            [_, rest] -> rest
            _ -> ""
          }
        })
      string.join(cleaned, "")
    }
  }
}

fn build_message_content(
  content: String,
  thread_target: Option(String),
) -> json.Json {
  json.object(message_content_fields(content, thread_target))
}

fn build_edit_content(
  content: String,
  thread_target: Option(String),
  message_id: String,
) -> json.Json {
  let new_content = build_message_content(content, thread_target)
  let fields =
    list.append(base_message_fields("* " <> content), [
      #("m.new_content", new_content),
      #("m.relates_to", replace_relation(message_id)),
    ])

  json.object(fields)
}

fn message_content_fields(
  content: String,
  thread_target: Option(String),
) -> List(#(String, json.Json)) {
  case thread_target {
    Some(parent_id) ->
      list.append(base_message_fields(content), [
        #("m.relates_to", thread_relation(parent_id)),
      ])
    None -> base_message_fields(content)
  }
}

fn base_message_fields(content: String) -> List(#(String, json.Json)) {
  [
    #("msgtype", json.string("m.text")),
    #("body", json.string(content)),
    #("format", json.string("org.matrix.custom.html")),
    #("formatted_body", json.string(render_html(content))),
  ]
}

fn thread_relation(parent_id: String) -> json.Json {
  json.object([
    #("rel_type", json.string("m.thread")),
    #("event_id", json.string(parent_id)),
  ])
}

fn replace_relation(message_id: String) -> json.Json {
  json.object([
    #("rel_type", json.string("m.replace")),
    #("event_id", json.string(message_id)),
  ])
}

fn render_html(content: String) -> String {
  content
  |> escape_html
  |> string.replace("\r\n", "\n")
  |> string.replace("\n", "<br>")
}

fn escape_html(content: String) -> String {
  content
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}

// ============================================================================
// Internal: Sending
// ============================================================================

fn do_send(
  homeserver_url: String,
  access_token: String,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  // Build the message payload
  case build_send_payload(reply) {
    Error(e) -> Error(e)
    Ok(payload) -> {
      let room_id = reply.channel_id
      let txn_id = generate_txn_id()
      let encoded_room_id = string.replace(room_id, each: ":", with: "%3A")
      let url =
        homeserver_url
        <> "/_matrix/client/v3/rooms/"
        <> encoded_room_id
        <> "/send/m.room.message/"
        <> txn_id

      case request.to(url) {
        Error(_) -> Error(port.SendFailed("invalid URL"))
        Ok(req) -> {
          let req =
            req
            |> request.set_method(http.Put)
            |> request.set_header("Authorization", "Bearer " <> access_token)
            |> request.set_header("Content-Type", "application/json")
            |> request.set_body(payload)

          case hackney.send(req) {
            Ok(response) -> handle_matrix_response(response)
            Error(hackney.InvalidUtf8Response) ->
              Error(port.SendFailed("Invalid UTF-8 response from homeserver"))
            Error(hackney.Other(reason)) ->
              Error(port.SendFailed("HTTP error: " <> string.inspect(reason)))
          }
        }
      }
    }
  }
}

fn do_send_and_get_event_id(
  homeserver_url: String,
  access_token: String,
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  case build_send_payload(reply) {
    Error(e) -> Error(e)
    Ok(payload) -> {
      let room_id = reply.channel_id
      let txn_id = generate_txn_id()
      let encoded_room_id = string.replace(room_id, each: ":", with: "%3A")
      let url =
        homeserver_url
        <> "/_matrix/client/v3/rooms/"
        <> encoded_room_id
        <> "/send/m.room.message/"
        <> txn_id

      case request.to(url) {
        Error(_) -> Error(port.SendFailed("invalid URL"))
        Ok(req) -> {
          let req =
            req
            |> request.set_method(http.Put)
            |> request.set_header("Authorization", "Bearer " <> access_token)
            |> request.set_header("Content-Type", "application/json")
            |> request.set_body(payload)

          case hackney.send(req) {
            Ok(response) -> handle_matrix_response_with_event_id(response)
            Error(hackney.InvalidUtf8Response) ->
              Error(port.SendFailed("Invalid UTF-8 response from homeserver"))
            Error(hackney.Other(reason)) ->
              Error(port.SendFailed("HTTP error: " <> string.inspect(reason)))
          }
        }
      }
    }
  }
}

fn handle_matrix_response_with_event_id(
  response: Response(String),
) -> Result(String, port.ChannelError) {
  case response.status {
    200 | 201 -> {
      let decoder =
        decode.field("event_id", decode.string, fn(v) { decode.success(v) })
      case json.parse(response.body, decoder) {
        Ok(event_id) -> Ok(event_id)
        Error(_) ->
          Error(port.SendFailed("could not parse event_id from response"))
      }
    }
    401 -> Error(port.SendFailed("Unauthorized - check access token"))
    403 -> Error(port.SendFailed("Forbidden - no permission to send in room"))
    404 -> Error(port.SendFailed("Room not found"))
    429 -> {
      let retry_after = parse_retry_after(response.body)
      Error(port.RateLimited(retry_after_seconds: retry_after))
    }
    status ->
      Error(port.SendFailed("Homeserver error: " <> int.to_string(status)))
  }
}

/// Generate a unique transaction ID for message sending.
/// Uses a new Erlang reference to guarantee uniqueness.
fn generate_txn_id() -> String {
  let ref = reference.new()
  "m"
  <> string.replace(string.inspect(ref), each: "#Ref<", with: "")
  |> string.replace(each: ">", with: "")
  |> string.replace(each: ".", with: "_")
}

/// Handle HTTP response from Matrix homeserver.
fn handle_matrix_response(
  response: Response(String),
) -> Result(Nil, port.ChannelError) {
  case response.status {
    200 | 201 -> Ok(Nil)
    401 -> Error(port.SendFailed("Unauthorized - check access token"))
    403 -> Error(port.SendFailed("Forbidden - no permission to send in room"))
    404 -> Error(port.SendFailed("Room not found"))
    429 -> {
      // Rate limited - try to parse retry_after
      let retry_after = parse_retry_after(response.body)
      Error(port.RateLimited(retry_after_seconds: retry_after))
    }
    status ->
      Error(port.SendFailed("Homeserver error: " <> int.to_string(status)))
  }
}

/// Parse retry_after from rate limit response.
fn parse_retry_after(body: String) -> Int {
  let decoder =
    decode.field("retry_after_ms", decode.int, fn(v) { decode.success(v) })
  case json.parse(body, decoder) {
    Ok(ms) -> ms / 1000
    Error(_) -> 30
  }
}
