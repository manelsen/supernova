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

/// Start the Mattermost adapter with the given config.
/// Returns a `ChannelAdapter` that the core uses to send replies.
pub fn start(
  bot_token: String,
  base_url: String,
  _handler: port.ChannelHandler,
) -> Result(port.ChannelAdapter, String) {
  let send_fn = fn(reply: port.ChannelReply) -> Result(Nil, port.ChannelError) {
    do_send(bot_token, base_url, reply)
  }

  Ok(
    port.ChannelAdapter(
      name: "mattermost",
      send: send_fn,
      stop: fn() { Nil },
      stop_ingress: fn() { Nil },
    ),
  )
}

/// Parse a raw Mattermost webhook/event JSON into a normalized `ChannelMessage`.
/// Returns `Error(port.Ignored(...))` for events that should be filtered.
pub fn parse_event(
  event_json: String,
) -> Result(port.ChannelMessage, port.ChannelError) {
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
    Some(message_id) ->
      json.object([
        #("channel_id", json.string(reply.channel_id)),
        #("message", json.string(reply.content)),
        #("root_id", json.string(message_id)),
      ])
    None ->
      json.object([
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
  use root_id <- decode.optional_field(
    "root_id",
    None,
    decode.string |> decode.map(Some),
  )
  use parent_id <- decode.optional_field(
    "parent_id",
    None,
    decode.string |> decode.map(Some),
  )
  use is_bot <- decode.optional_field(
    "is_bot",
    None,
    decode.bool |> decode.map(fn(x) { Some(x) }),
  )

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

fn normalize_event(
  event: MattermostEvent,
) -> Result(port.ChannelMessage, port.ChannelError) {
  // Filter: ignore bot messages
  case event.is_bot {
    Some(True) -> Error(port.Ignored("bot sender filtered"))
    _ -> normalize_user_event(event)
  }
}

fn normalize_user_event(
  event: MattermostEvent,
) -> Result(port.ChannelMessage, port.ChannelError) {
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
        username: "",
        // Would need to fetch user info
        content: event.message,
        is_bot: False,
        reply_to_id: reply_to_id,
      ))
    }
  }
}

fn do_send(
  token: String,
  base_url: String,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  case build_reply_payload(reply) {
    Error(e) -> Error(e)
    Ok(payload) -> {
      let url = join_url(base_url, "/api/v4/posts")

      case request.to(url) {
        Error(_) -> Error(port.SendFailed("invalid Mattermost base URL"))
        Ok(req) -> {
          let req =
            req
            |> request.set_method(http.Post)
            |> request.set_header("Authorization", "Bearer " <> token)
            |> request.set_header("Content-Type", "application/json")
            |> request.set_body(payload)

          case hackney.send(req) {
            Ok(response) -> handle_mattermost_response(response)
            Error(hackney.InvalidUtf8Response) ->
              Error(port.SendFailed("Invalid UTF-8 response from Mattermost"))
            Error(hackney.Other(reason)) ->
              Error(port.SendFailed("HTTP error: " <> string.inspect(reason)))
          }
        }
      }
    }
  }
}

fn join_url(base_url: String, path: String) -> String {
  case string.ends_with(base_url, "/") {
    True -> string.drop_end(base_url, 1) <> path
    False -> base_url <> path
  }
}

/// Handle HTTP response from Mattermost webhook.
fn handle_mattermost_response(
  response: Response(String),
) -> Result(Nil, port.ChannelError) {
  case response.status {
    200 | 201 -> Ok(Nil)
    400 -> Error(port.SendFailed("Bad request - invalid payload"))
    401 -> Error(port.SendFailed("Unauthorized - check token"))
    403 -> Error(port.SendFailed("Forbidden - no permission to post"))
    429 -> {
      let retry_after = parse_mattermost_retry_after(response.body)
      Error(port.RateLimited(retry_after_seconds: retry_after))
    }
    status ->
      Error(port.SendFailed("Mattermost error: " <> int.to_string(status)))
  }
}

/// Parse retry_after from rate limit response.
fn parse_mattermost_retry_after(body: String) -> Int {
  // Mattermost may include retry_after in response body
  case
    json.parse(
      body,
      decode.field("retry_after", decode.int, fn(v) { decode.success(v) }),
    )
  {
    Ok(value) -> value
    Error(_) -> 30
  }
}
