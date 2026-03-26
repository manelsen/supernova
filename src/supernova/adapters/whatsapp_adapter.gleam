//// WhatsApp Adapter — implements the ChannelPort contract for WhatsApp Cloud API.
////
//// WhatsApp uses the Cloud API webhooks format. This adapter normalizes
//// incoming webhook events to `ChannelMessage` and renders `ChannelReply`
//// back to WhatsApp Cloud API message format.
////
//// ## WhatsApp Cloud API Specifics
////
//// - **Phone Number ID:** The `phone_number_id` from metadata is the channel_id
//// - **User ID:** The user's WhatsApp number (`from` field) is the user_id
//// - **Message Types:** text, image, audio, video, document, sticker, etc.
//// - **Threading:** Via `context.message_id` field for replies
////

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port
import supernova/channel/session.{type SessionResolver, without_manager}

// ============================================================================
// Configuration
// ============================================================================

/// The bot's own phone number. Messages from this number are filtered out.
const bot_phone_number: String = "15550000000"  // Different from test fixtures

// ============================================================================
// Public API
// ============================================================================

/// Parse a raw WhatsApp Cloud API webhook event JSON into a normalized `ChannelMessage`.
/// Returns `Error(port.Ignored(...))` for events that should be filtered.
pub fn parse_event(event_json: String) -> Result(port.ChannelMessage, port.ChannelError) {
  case json.parse(event_json, whatsapp_webhook_decoder()) {
    Ok(event) -> normalize_event(event)
    Error(_) -> Error(port.SendFailed("invalid JSON"))
  }
}

/// Build the WhatsApp Cloud API message payload for sending a reply.
pub fn build_reply_payload(
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  let base_payload = json.object([
    #("messaging_product", json.string("whatsapp")),
    #("to", json.string(reply.channel_id)),
  ])
  
  // Build the appropriate message object based on content
  let message_obj = case reply.interactive {
    Some(_) -> build_interactive_message(reply)
    None -> build_text_message(reply)
  }
  
  // Combine base payload with message object
  let payload = case reply.reply_to_id {
    Some(parent_id) -> {
      // Add context for reply threading
      json.object([
        #("messaging_product", json.string("whatsapp")),
        #("to", json.string(reply.channel_id)),
        #("type", json.string("text")),
        #("text", message_obj),
        #("context", json.object([
          #("message_id", json.string(parent_id)),
        ])),
      ])
    }
    None -> {
      let type_key = case reply.interactive {
        Some(_) -> "interactive"
        None -> "text"
      }
      json.object([
        #("messaging_product", json.string("whatsapp")),
        #("to", json.string(reply.channel_id)),
        #("type", json.string(type_key)),
        #("text", message_obj),
      ])
    }
  }
  
  Ok(json.to_string(payload))
}

/// Resolve the session ID for a WhatsApp message.
/// Format: `whatsapp:{phone_number_id}:{user_whatsapp_number}`
pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  "whatsapp:" <> msg.channel_id <> ":" <> msg.user_id
}

/// Create a session resolver for WhatsApp.
pub fn session_resolver() -> SessionResolver {
  without_manager("whatsapp")
}

// ============================================================================
// Internal: Event Decoding
// ============================================================================

fn whatsapp_webhook_decoder() -> decode.Decoder(WhatsAppWebhook) {
  use object <- decode.field("object", decode.string)
  use entry <- decode.field("entry", decode.list(whatsapp_entry_decoder()))
  decode.success(WhatsAppWebhook(object: object, entry: entry))
}

fn whatsapp_entry_decoder() -> decode.Decoder(WhatsAppEntry) {
  use id <- decode.field("id", decode.string)
  use changes <- decode.field("changes", decode.list(whatsapp_change_decoder()))
  decode.success(WhatsAppEntry(id: id, changes: changes))
}

fn whatsapp_change_decoder() -> decode.Decoder(WhatsAppChange) {
  use value <- decode.field("value", whatsapp_value_decoder())
  use field <- decode.field("field", decode.string)
  decode.success(WhatsAppChange(value: value, field: field))
}

fn whatsapp_value_decoder() -> decode.Decoder(WhatsAppValue) {
  use messaging_product <- decode.optional_field("messaging_product", None, decode.string |> decode.map(Some))
  use metadata <- decode.optional_field("metadata", None, whatsapp_metadata_decoder() |> decode.map(Some))
  use contacts <- decode.optional_field("contacts", None, decode.list(whatsapp_contact_decoder()) |> decode.map(Some))
  use messages <- decode.optional_field("messages", None, decode.list(whatsapp_message_decoder()) |> decode.map(Some))
  use statuses <- decode.optional_field("statuses", None, decode.list(whatsapp_status_decoder()) |> decode.map(Some))
  decode.success(WhatsAppValue(
    messaging_product: messaging_product,
    metadata: metadata,
    contacts: contacts,
    messages: messages,
    statuses: statuses,
  ))
}

fn whatsapp_metadata_decoder() -> decode.Decoder(WhatsAppMetadata) {
  use phone_number_id <- decode.field("phone_number_id", decode.string)
  use display_phone_number <- decode.field("display_phone_number", decode.string)
  decode.success(WhatsAppMetadata(
    phone_number_id: phone_number_id,
    display_phone_number: display_phone_number,
  ))
}

fn whatsapp_contact_decoder() -> decode.Decoder(WhatsAppContact) {
  use profile <- decode.field("profile", whatsapp_profile_decoder())
  use wa_id <- decode.field("wa_id", decode.string)
  decode.success(WhatsAppContact(profile: profile, wa_id: wa_id))
}

fn whatsapp_profile_decoder() -> decode.Decoder(WhatsAppProfile) {
  use name <- decode.field("name", decode.string)
  decode.success(WhatsAppProfile(name: name))
}

fn whatsapp_message_decoder() -> decode.Decoder(WhatsAppMessage) {
  use from <- decode.field("from", decode.string)
  use id <- decode.field("id", decode.string)
  use timestamp <- decode.field("timestamp", decode.string)
  use msg_type <- decode.field("type", decode.string)
  use text <- decode.optional_field("text", None, whatsapp_text_decoder() |> decode.map(Some))
  use caption <- decode.optional_field("caption", None, decode.string |> decode.map(Some))
  use context <- decode.optional_field("context", None, whatsapp_context_decoder() |> decode.map(Some))
  decode.success(WhatsAppMessage(
    from: from,
    id: id,
    timestamp: timestamp,
    msg_type: msg_type,
    text: text,
    caption: caption,
    context: context,
  ))
}

fn whatsapp_text_decoder() -> decode.Decoder(WhatsAppText) {
  use body <- decode.field("body", decode.string)
  decode.success(WhatsAppText(body: body))
}

fn whatsapp_context_decoder() -> decode.Decoder(WhatsAppContext) {
  use from <- decode.field("from", decode.string)
  use id <- decode.field("id", decode.string)
  decode.success(WhatsAppContext(from: from, id: id))
}

fn whatsapp_status_decoder() -> decode.Decoder(WhatsAppStatus) {
  use id <- decode.field("id", decode.string)
  use from <- decode.field("from", decode.string)
  use timestamp <- decode.field("timestamp", decode.string)
  use status <- decode.field("status", decode.string)
  decode.success(WhatsAppStatus(
    id: id,
    from: from,
    timestamp: timestamp,
    status: status,
  ))
}

// ============================================================================
// Internal: Type Definitions
// ============================================================================

type WhatsAppWebhook {
  WhatsAppWebhook(object: String, entry: List(WhatsAppEntry))
}

type WhatsAppEntry {
  WhatsAppEntry(id: String, changes: List(WhatsAppChange))
}

type WhatsAppChange {
  WhatsAppChange(value: WhatsAppValue, field: String)
}

type WhatsAppValue {
  WhatsAppValue(
    messaging_product: Option(String),
    metadata: Option(WhatsAppMetadata),
    contacts: Option(List(WhatsAppContact)),
    messages: Option(List(WhatsAppMessage)),
    statuses: Option(List(WhatsAppStatus)),
  )
}

type WhatsAppMetadata {
  WhatsAppMetadata(phone_number_id: String, display_phone_number: String)
}

type WhatsAppContact {
  WhatsAppContact(profile: WhatsAppProfile, wa_id: String)
}

type WhatsAppProfile {
  WhatsAppProfile(name: String)
}

type WhatsAppMessage {
  WhatsAppMessage(
    from: String,
    id: String,
    timestamp: String,
    msg_type: String,
    text: Option(WhatsAppText),
    caption: Option(String),
    context: Option(WhatsAppContext),
  )
}

type WhatsAppText {
  WhatsAppText(body: String)
}

type WhatsAppContext {
  WhatsAppContext(from: String, id: String)
}

type WhatsAppStatus {
  WhatsAppStatus(id: String, from: String, timestamp: String, status: String)
}

// ============================================================================
// Internal: Normalization Logic
// ============================================================================

fn normalize_event(event: WhatsAppWebhook) -> Result(port.ChannelMessage, port.ChannelError) {
  // Get the first entry and first change
  case event.entry {
    [first_entry, ..] -> {
      case first_entry.changes {
        [first_change, ..] -> {
          let value = first_change.value
          normalize_value(value)
        }
        _ -> Error(port.Ignored("no changes in entry"))
      }
    }
    _ -> Error(port.Ignored("no entries in webhook"))
  }
}

fn normalize_value(value: WhatsAppValue) -> Result(port.ChannelMessage, port.ChannelError) {
  // Filter: must have metadata (phone_number_id)
  case value.metadata {
    Some(metadata) -> normalize_value_with_metadata(value, metadata)
    None -> Error(port.Ignored("missing metadata"))
  }
}

fn normalize_value_with_metadata(
  value: WhatsAppValue,
  metadata: WhatsAppMetadata,
) -> Result(port.ChannelMessage, port.ChannelError) {
  // Check if we have messages
  case value.messages {
    Some([first_message, ..]) -> normalize_message(first_message, metadata)
    Some([]) -> Error(port.Ignored("no messages in value"))
    None -> {
      // Check for statuses (these should be ignored)
      case value.statuses {
        Some([first_status, ..]) -> Error(port.Ignored("unsupported message type: " <> first_status.status))
        _ -> Error(port.Ignored("no messages in value"))
      }
    }
  }
}

fn normalize_message(
  msg: WhatsAppMessage,
  metadata: WhatsAppMetadata,
) -> Result(port.ChannelMessage, port.ChannelError) {
  // Filter: ignore messages from the bot itself
  case msg.from == bot_phone_number {
    True -> Error(port.Ignored("bot sender filtered"))
    False -> normalize_user_message(msg, metadata)
  }
}

fn normalize_user_message(
  msg: WhatsAppMessage,
  metadata: WhatsAppMetadata,
) -> Result(port.ChannelMessage, port.ChannelError) {
  // Extract text content based on message type
  let content = case msg.msg_type {
    "text" -> {
      case msg.text {
        Some(t) -> t.body
        None -> ""
      }
    }
    // Media messages may have captions
    "image" | "video" | "document" | "sticker" -> {
      case msg.caption {
        Some(caption) -> caption
        None -> ""
      }
    }
    // Audio, location, contacts, etc. have no text content
    _ -> ""
  }
  
  // Filter: ignore empty content
  case string.is_empty(content) {
    True -> Error(port.Ignored("empty content"))
    False -> {
      // Extract reply_to_id from context if present
      let reply_to = case msg.context {
        Some(ctx) -> Some(ctx.id)
        None -> None
      }
      
      Ok(port.ChannelMessage(
        id: msg.id,
        channel: "whatsapp",
        channel_id: metadata.phone_number_id,
        user_id: msg.from,
        username: "",  // Would need to fetch from contacts
        content: content,
        is_bot: False,
        reply_to_id: reply_to,
      ))
    }
  }
}

// ============================================================================
// Internal: Message Building
// ============================================================================

fn build_text_message(reply: port.ChannelReply) -> json.Json {
  json.object([
    #("body", json.string(reply.content)),
  ])
}

fn build_interactive_message(reply: port.ChannelReply) -> json.Json {
  case reply.interactive {
    Some(interactive) -> {
      let blocks = build_interactive_blocks(interactive.blocks)
      json.object([
        #("body", json.string(reply.content)),
        #("action", json.object([
          #("buttons", json.array(blocks, fn(b) { b })),
        ])),
      ])
    }
    None -> build_text_message(reply)
  }
}

fn build_interactive_blocks(blocks: List(port.ChannelInteractionBlock)) -> List(json.Json) {
  list.filter_map(blocks, fn(block) {
    case block {
      port.InteractionButtons(buttons) -> Ok(build_buttons(buttons))
      _ -> Error(Nil)  // Only buttons supported for now
    }
  })
}

fn build_buttons(buttons: List(port.ChannelButton)) -> json.Json {
  json.array(buttons, fn(btn: port.ChannelButton) {
    let label = btn.label
    let action_id = btn.action_id
    let button_type = case btn.style {
      port.ButtonPrimary -> "reply"
      _ -> "reply"
    }
    json.object([
      #("type", json.string(button_type)),
      #("reply", json.object([
        #("id", json.string(action_id)),
        #("title", json.string(label)),
      ])),
    ])
  })
}

// ============================================================================
// Internal: Sending (Stub)
// ============================================================================

fn do_send(
  _phone_number_id: String,
  _access_token: String,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  case build_reply_payload(reply) {
    Error(e) -> Error(e)
    Ok(_payload) -> {
      // TODO: Implement actual HTTP POST to WhatsApp Cloud API
      // POST https://graph.facebook.com/v18.0/{phone_number_id}/messages
      // Headers: Authorization: Bearer {access_token}
      // Body: {payload}
      //
      // For now, return NotConnected to indicate this needs implementation
      Error(port.NotConnected)
    }
  }
}
