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
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port
import supernova/channel/session.{type SessionResolver, without_manager}

// ============================================================================
// Public API
// ============================================================================

/// Start the Slack adapter with the given config.
/// Returns a `ChannelAdapter` that the core uses to send replies.
pub fn start(
  bot_token: String,
  signing_secret: String,
  _handler: port.ChannelHandler,
) -> Result(port.ChannelAdapter, String) {
  let send_fn = fn(reply: port.ChannelReply) -> Result(Nil, port.ChannelError) {
    do_send(bot_token, reply)
  }

  Ok(port.ChannelAdapter(
    name: "slack",
    send: send_fn,
  ))
}

/// Parse a raw Slack event JSON into a normalized `ChannelMessage`.
/// Returns `Error(port.Ignored(...))` for events that should be filtered.
pub fn parse_event(event_json: String) -> Result(port.ChannelMessage, port.ChannelError) {
  case json.parse(event_json, slack_event_decoder()) {
    Ok(event) -> normalize_event(event)
    Error(_) -> Error(port.SendFailed("invalid JSON"))
  }
}

/// Build the Slack message payload for sending a reply.
pub fn build_reply_payload(
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  let blocks = case reply.interactive {
    Some(interactive) -> build_interactive_blocks(interactive)
    None -> []
  }

  let payload = case reply.reply_to_id {
    Some(thread_ts) -> json.object([
      #("channel", json.string(reply.channel_id)),
      #("text", json.string(reply.content)),
      #("thread_ts", json.string(thread_ts)),
      #("blocks", json.array(blocks, json.string)),
    ])
    None -> json.object([
      #("channel", json.string(reply.channel_id)),
      #("text", json.string(reply.content)),
      #("blocks", json.array(blocks, json.string)),
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
  use thread_ts <- decode.optional_field("thread_ts", None, decode.string |> decode.map(Some))
  use bot_id <- decode.optional_field("bot_id", None, decode.string |> decode.map(Some))

  decode.success(SlackEvent(
    event_type: event_type,
    user: user,
    text: text,
    channel: channel,
    ts: ts,
    thread_ts: thread_ts,
    bot_id: bot_id,
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
  )
}

// ============================================================================
// Internal: Normalization Logic
// ============================================================================

fn normalize_event(event: SlackEvent) -> Result(port.ChannelMessage, port.ChannelError) {
  // Filter: ignore bot messages
  case event.bot_id {
    Some(_) -> Error(port.Ignored("bot sender filtered"))
    None -> normalize_user_event(event)
  }
}

fn normalize_user_event(event: SlackEvent) -> Result(port.ChannelMessage, port.ChannelError) {
  // Filter: ignore empty content
  case string.is_empty(event.text) {
    True -> Error(port.Ignored("empty content"))
    False -> Ok(port.ChannelMessage(
      id: event.ts,
      channel: "slack",
      channel_id: event.channel,
      user_id: event.user,
      username: "",  // Would need to fetch user info
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

fn build_interactive_blocks(interactive: port.ChannelInteractiveReply) -> List(String) {
  list.map(interactive.blocks, build_block)
}

fn build_block(block: port.ChannelInteractionBlock) -> String {
  case block {
    port.InteractionText(text) -> "{\"type\": \"section\", \"text\": {\"type\": \"mrkdwn\", \"text\": \"" <> escape_json(text) <> "\"}}"
    port.InteractionButtons(buttons) -> build_buttons_block(buttons)
    port.InteractionSelect(action_id:, placeholder:, options:) -> build_select_block(placeholder, options)
  }
}

fn build_buttons_block(buttons: List(port.ChannelButton)) -> String {
  let actions = list.map(buttons, fn(btn: port.ChannelButton) {
    let label = port.button_label(btn)
    let action_id = port.button_action_id(btn)
    let style = case port.button_style(btn) {
      port.ButtonPrimary -> "primary"
      port.ButtonDanger -> "danger"
      _ -> ""
    }
    "{\"type\": \"button\", \"text\": {\"type\": \"plain_text\", \"text\": \"" <> escape_json(label) <> "\"}, \"action_id\": \"" <> action_id <> "\", \"style\": \"" <> style <> "\"}"
  })
  "{\"type\": \"actions\", \"elements\": [" <> string.join(actions, ",") <> "]}"
}

fn build_select_block(placeholder: Option(String), options: List(port.ChannelSelectOption)) -> String {
  let placeholder_text = placeholder |> option.unwrap("Select an option")
  let option_strings = list.map(options, fn(opt: port.ChannelSelectOption) {
    let label = port.select_option_label(opt)
    let value = port.select_option_value(opt)
    "{\"text\": {\"type\": \"plain_text\", \"text\": \"" <> escape_json(label) <> "\"}, \"value\": \"" <> value <> "\"}"
  })
  "{\"type\": \"section\", \"text\": {\"type\": \"mrkdwn\", \"text\": \"_\"}, \"accessory\": {\"type\": \"static_select\", \"placeholder\": {\"type\": \"plain_text\", \"text\": \"" <> escape_json(placeholder_text) <> "\"}, \"options\": [" <> string.join(option_strings, ",") <> "]}}"
}



fn escape_json(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

// ============================================================================
// Internal: Sending
// ============================================================================

fn do_send(
  _bot_token: String,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  case build_reply_payload(reply) {
    Error(e) -> Error(e)
    Ok(_payload) -> {
      // TODO: Implement actual HTTP POST to Slack API
      // POST https://slack.com/api/chat.postMessage
      // Headers: Authorization: Bearer {bot_token}
      // Body: {payload}
      //
      // For now, return NotConnected to indicate this needs implementation
      Error(port.NotConnected)
    }
  }
}
