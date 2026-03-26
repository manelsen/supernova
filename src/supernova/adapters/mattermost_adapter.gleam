//// Mattermost Adapter — implements the ChannelPort contract for Mattermost.
////
//// Mattermost uses incoming webhooks and the REST API.
//// This adapter normalizes Mattermost webhook events to `ChannelMessage`
//// and renders `ChannelReply` back to Mattermost message format.
////
//// ## Mattermost Specifics
////
//// - **Channel IDs:** Alphanumeric strings identifying channels
//// - **User IDs:** Alphanumeric strings identifying users
//// - **Bot IDs:** Mattermost bots have `is_bot: true` in the event
//// - **Threading:** Via `root_id` (original message) and `parent_id` (immediate parent)
//// - **Message format:** Uses `message` field for text content

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port
import supernova/channel/session.{type SessionResolver, without_manager}

// ============================================================================
// Public API
// ============================================================================

/// Start the Mattermost adapter with the given config.
/// Returns a `ChannelAdapter` that the core uses to send replies.
pub fn start(
  _bot_token: String,
  webhook_url: String,
  _handler: port.ChannelHandler,
) -> Result(port.ChannelAdapter, String) {
  let send_fn = fn(reply: port.ChannelReply) -> Result(Nil, port.ChannelError) {
    do_send(webhook_url, reply)
  }

  Ok(port.ChannelAdapter(
    name: "mattermost",
    send: send_fn,
  ))
}

/// Parse a raw Mattermost webhook/event JSON into a normalized `ChannelMessage`.
/// Returns `Error(port.Ignored(...))` for events that should be filtered.
pub fn parse_event(event_json: String) -> Result(port.ChannelMessage, port.ChannelError) {
  case json.parse(event_json, mattermost_event_decoder()) {
    Ok(event) -> normalize_event(event)
    Error(_) -> Error(port.SendFailed("invalid JSON"))
  }
}

/// Build the Mattermost message payload for sending a reply.
pub fn build_reply_payload(
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  let payload = case reply.reply_to_id {
    Some(message_id) -> json.object([
      #("channel_id", json.string(reply.channel_id)),
      #("message", json.string(reply.content)),
      #("root_id", json.string(message_id)),
    ])
    None -> json.object([
      #("channel_id", json.string(reply.channel_id)),
      #("message", json.string(reply.content)),
    ])
  }

  Ok(json.to_string(payload))
}

/// Resolve the session ID for a Mattermost message.
pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  "mattermost:" <> msg.channel_id <> ":" <> msg.user_id
}

/// Create a session resolver for Mattermost.
pub fn session_resolver() -> SessionResolver {
  without_manager("mattermost")
}


// ============================================================================
// Internal: Event Decoding
// ============================================================================

fn mattermost_event_decoder() -> decode.Decoder(MattermostEvent) {
  use id <- decode.field("id", decode.string)
  use channel_id <- decode.field("channel_id", decode.string)
  use user_id <- decode.field("user_id", decode.string)
  use message <- decode.field("message", decode.string)
  use create_at <- decode.field("create_at", decode.int)
  use root_id <- decode.optional_field("root_id", None, decode.string |> decode.map(Some))
  use parent_id <- decode.optional_field("parent_id", None, decode.string |> decode.map(Some))
  use is_bot <- decode.optional_field("is_bot", None, decode.bool |> decode.map(fn(x) { Some(x) }))

  decode.success(MattermostEvent(
    id: id,
    channel_id: channel_id,
    user_id: user_id,
    message: message,
    create_at: create_at,
    root_id: root_id,
    parent_id: parent_id,
    is_bot: is_bot,
  ))
}

type MattermostEvent {
  MattermostEvent(
    id: String,
    channel_id: String,
    user_id: String,
    message: String,
    create_at: Int,
    root_id: Option(String),
    parent_id: Option(String),
    is_bot: Option(Bool),
  )
}

// ============================================================================
// Internal: Normalization Logic
// ============================================================================

fn normalize_event(event: MattermostEvent) -> Result(port.ChannelMessage, port.ChannelError) {
  // Filter: ignore bot messages
  case event.is_bot {
    Some(True) -> Error(port.Ignored("bot sender filtered"))
    _ -> normalize_user_event(event)
  }
}

fn normalize_user_event(event: MattermostEvent) -> Result(port.ChannelMessage, port.ChannelError) {
  // Filter: ignore empty content
  case string.is_empty(event.message) {
    True -> Error(port.Ignored("empty content"))
    False -> {
      // Determine reply_to_id: prefer root_id, fall back to parent_id
      let reply_to_id = case event.root_id, event.parent_id {
        Some(root), _ -> Some(root)
        None, Some(parent) -> Some(parent)
        None, None -> None
      }

      Ok(port.ChannelMessage(
        id: event.id,
        channel: "mattermost",
        channel_id: event.channel_id,
        user_id: event.user_id,
        username: "",  // Would need to fetch user info
        content: event.message,
        is_bot: False,
        reply_to_id: reply_to_id,
      ))
    }
  }
}

// ============================================================================
// Internal: Sending
// ============================================================================

fn do_send(
  _webhook_url: String,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  case build_reply_payload(reply) {
    Error(e) -> Error(e)
    Ok(_payload) -> {
      // TODO: Implement actual HTTP POST to Mattermost webhook/API
      // POST {webhook_url}
      // Headers: Content-Type: application/json
      // Body: {payload}
      //
      // For now, return NotConnected to indicate this needs implementation
      Error(port.NotConnected)
    }
  }
}
