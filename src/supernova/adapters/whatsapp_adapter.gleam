//// WhatsApp Adapter — bridge-first adapter for Whatsmeow-compatible REST APIs.
////
//// The primary target is `go-whatsapp-web-multidevice`, which exposes:
//// - inbound webhook payloads with `event`, `device_id`, and `payload`
//// - outbound REST endpoints such as `/send/message`, `/send/image`,
////   `/send/audio`, and `/send/file`
////
//// The adapter keeps the legacy Cloud-style parser as a fallback so existing
//// fixtures keep working while the runtime moves to the bridge transport.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response, set_body}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/adapters/whatsapp_inbound
import supernova/channel/channel_kit
import supernova/channel/inbound_media
import supernova/channel/pairing
import supernova/channel/port
import supernova/channel/session.{type SessionResolver, without_manager}
import supernova/channel/traits/whatsapp as whatsapp_traits
import supernova/channel/voice
import supernova/channel/webhook_server
import supernova/core/closed_group/global as closed_group_global
import supernova/core/closed_group/runtime as closed_group_runtime
import supernova/core/identity/aliases
import supernova/metrics/record
import supernova/tools/web

const multipart_boundary: String = "supernova-whatsapp-bridge"

const default_file_mime_type: String = "application/octet-stream"

pub type BridgeContentType {
  BridgeJson
  BridgeMultipart
}

pub type BridgeDownload {
  BridgeDownload(
    field_name: String,
    source_url: String,
    filename: String,
    mime_type: Option(String),
  )
}

pub type BridgeRequestPlan {
  BridgeRequestPlan(
    path: String,
    content_type: BridgeContentType,
    fields: List(#(String, String)),
    download: Option(BridgeDownload),
  )
}

/// What the adapter needs from configuration.
pub type Settings {
  Settings(
    bridge_url: String,
    device_id: Option(String),
    /// `user:password` of GOWA's basic auth.
    basic_auth: String,
    /// Shared secret of the webhook signature.
    webhook_secret: String,
    data_dir: String,
    /// Groups are off unless `whatsapp.allow_groups` is on.
    allow_groups: Bool,
  )
}

/// Start the WhatsApp channel: outbound through GOWA's REST API, inbound
/// through the webhook server (`POST /webhook/whatsapp`, signed with the
/// shared secret). `on_down` reports a lost account to channel health.
pub fn start(
  settings: Settings,
  handler: port.ChannelHandler,
  hooks: channel_kit.StartHooks,
  on_down: fn(String) -> Nil,
) -> Result(port.ChannelAdapter, String) {
  let send_fn = fn(reply: port.ChannelReply) -> Result(Nil, port.ChannelError) {
    do_send(settings, reply)
  }
  let stream_fn =
    channel_kit.final_only_stream_send(
      send_fn,
      whatsapp_traits.max_message_length,
      channel_kit.stream_timeout_ms,
    )
  webhook_server.register(
    webhook_server.Route(
      channel: "whatsapp",
      verify: fn(headers, body) {
        case list.key_find(headers, "x-hub-signature-256") {
          Ok(signature) ->
            webhook_server.hub_signature_valid(
              settings.webhook_secret,
              body,
              signature,
            )
          Error(Nil) -> False
        }
      },
      translate: fn(body) {
        case bit_array.to_string(body) {
          Error(Nil) -> webhook_server.Malformed
          Ok(text) ->
            act(
              case settings.allow_groups {
                True -> whatsapp_inbound.decide_allowing_groups(text)
                False -> whatsapp_inbound.decide(text)
              },
              settings,
              send_fn,
              on_down,
            )
        }
      },
      dispatch: fn(inbound) {
        channel_kit.dispatch_inbound(
          handler,
          send_fn,
          stream_fn,
          inbound,
          hooks.registry_id,
          hooks.turn_hard_timeout_ms,
        )
      },
    ),
  )

  pairing.register("whatsapp", fn() { pairing_code(settings) })

  Ok(
    port.ChannelAdapter(
      name: "whatsapp",
      send: send_fn,
      stop: fn() {
        webhook_server.unregister("whatsapp")
        pairing.unregister("whatsapp")
      },
      stop_ingress: fn() { webhook_server.unregister("whatsapp") },
    ),
  )
}

/// A pairing code for the agent's number, asked of GOWA
/// (`GET /app/login-with-code?phone=…`, documented in GOWA v9.10's
/// openapi; the answer carries `results.pair_code`). The number comes from
/// the device id (`5511…@s.whatsapp.net`).
pub fn pairing_code(settings: Settings) -> Result(String, String) {
  case settings.device_id {
    None -> Error("SUPERNOVA_WHATSAPP_DEVICE_ID is not set")
    Some(device) -> {
      let phone = case string.split_once(device, "@") {
        Ok(#(digits, _)) -> digits
        Error(Nil) -> device
      }
      let url =
        join_bridge_url(
          settings.bridge_url,
          "/app/login-with-code?phone=" <> phone,
        )
      case request.to(url) {
        Error(_) -> Error("invalid bridge URL")
        Ok(req) -> {
          let req =
            req
            |> request.set_method(http.Get)
            |> maybe_set_device_header(settings.device_id)
            |> request.set_header(
              "Authorization",
              basic_authorization(settings.basic_auth),
            )
          case hackney.send(req) {
            Ok(response) if response.status == 200 ->
              json.parse(
                response.body,
                decode.at(["results", "pair_code"], decode.string),
              )
              |> result.replace_error("GOWA answered without a code")
            Ok(response) ->
              Error("GOWA answered " <> int.to_string(response.status))
            Error(_) -> Error("GOWA unreachable")
          }
        }
      }
    }
  }
}

/// Carry out a decision about one webhook.
pub fn act(
  decision: whatsapp_inbound.Decision,
  settings: Settings,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  on_down: fn(String) -> Nil,
) -> webhook_server.Outcome {
  case decision {
    whatsapp_inbound.Answer(message, learned, attachments, forwarded) -> {
      case learned {
        Some(#(lid, phone)) -> learn_lid(settings.data_dir, lid, phone)
        None -> Nil
      }
      let content =
        list.fold(attachments, message.content, fn(content, attachment) {
          content <> open_attachment(settings, attachment, forwarded)
        })
      webhook_server.Deliver([
        port.InboundMessage(port.ChannelMessage(..message, content: content)),
      ])
    }
    whatsapp_inbound.AskPrivate(chat_id, reply_to) -> {
      record.count("whatsapp_unknown_lid_total", [#("chat", "group")])
      let _ =
        send_fn(port.reply(
          to: port.ChannelMessage(
            id: reply_to,
            channel: "whatsapp",
            channel_id: chat_id,
            user_id: "",
            username: "",
            content: "",
            is_bot: False,
            reply_to_id: None,
          ),
          content: whatsapp_inbound.ask_private_text,
        ))
      webhook_server.Handled
    }
    whatsapp_inbound.Ignore("groups are off") -> {
      record.count("whatsapp_group_messages_dropped_total", [])
      webhook_server.Handled
    }
    whatsapp_inbound.Ignore("unknown lid") -> {
      record.count("whatsapp_unknown_lid_total", [#("chat", "private")])
      io.println("warn: whatsapp message from an unknown LID was not answered")
      webhook_server.Handled
    }
    whatsapp_inbound.Ignore(_) -> webhook_server.Handled
    whatsapp_inbound.AccountDown(reason, logged_out) -> {
      record.count("whatsapp_account_down_total", [])
      io.println("error: whatsapp " <> reason)
      on_down(reason)
      // Logged out: the alert already carries a new pairing code (PRD-A,
      // A-12). Suspended: the session is kept; the alert says until when.
      let next_step = case logged_out {
        False -> ""
        True ->
          case pairing.request("whatsapp") {
            Ok(code) -> "\n" <> pairing.whatsapp_instructions(code)
            Error(why) ->
              "\nNão consegui pedir o código de reconexão ("
              <> why
              <> "). Mande /parear aqui para tentar de novo."
          }
      }
      case closed_group_global.get_runtime() {
        Some(runtime) ->
          closed_group_runtime.channel_down_alert(
            runtime,
            "whatsapp",
            reason,
            "O WhatsApp caiu: " <> reason <> "." <> next_step,
          )
        None -> Nil
      }
      webhook_server.Handled
    }
    whatsapp_inbound.Malformed -> webhook_server.Malformed
  }
}

/// What an attachment becomes in the message text (PRD-A, A-01): an
/// image (or a still sticker) goes to the model; what the agent cannot
/// open yet becomes a note it can answer, never silence.
fn open_attachment(
  settings: Settings,
  attachment: whatsapp_inbound.Attachment,
  forwarded: Bool,
) -> String {
  let kind = case attachment.kind {
    whatsapp_inbound.Audio -> Ok(inbound_media.Audio)
    whatsapp_inbound.Video -> Ok(inbound_media.Video)
    whatsapp_inbound.Document -> Ok(inbound_media.Document)
    // Read frame by frame at the start of the turn (A-10).
    whatsapp_inbound.AnimatedSticker -> Ok(inbound_media.Sticker)
    _ -> Error(Nil)
  }
  case attachment.kind, attachment.path, kind {
    whatsapp_inbound.Image, Some(path), _
    | whatsapp_inbound.Sticker, Some(path), _
    -> fetch_image(settings, path)
    // Audio, video and documents are kept for the reader at the start of
    // the turn (PRD-A, A-04).
    _, Some(path), Ok(kind) ->
      case
        safe_media_path(path),
        inbound_media.fetch(
          settings.data_dir,
          join_bridge_url(settings.bridge_url, "/" <> path),
          inbound_media.Declared(
            kind: kind,
            mime: attachment.mime,
            seconds: attachment.seconds,
            file_name: attachment.file_name,
            voice_note: attachment.voice_note,
            forwarded: forwarded,
          ),
        )
      {
        True, Ok(media) -> {
          record.count("channel_media_total", [
            #("channel", "whatsapp"),
            #("outcome", "kept"),
          ])
          inbound_media.tag_for(media)
        }
        _, _ -> {
          record.count("channel_media_total", [
            #("channel", "whatsapp"),
            #("outcome", "failed"),
          ])
          "\n" <> whatsapp_inbound.unopened_note(attachment, forwarded)
        }
      }
    _, _, _ -> "\n" <> whatsapp_inbound.unopened_note(attachment, forwarded)
  }
}

/// GOWA serves its downloads under `statics/media/`; nothing else.
fn safe_media_path(path: String) -> Bool {
  string.starts_with(path, "statics/media/") && !string.contains(path, "..")
}

/// The tag of an image GOWA downloaded (PRD-C, C-05), or a note that it
/// could not be opened. GOWA serves its downloads under `/statics/media/`
/// on the internal network; nothing else is fetched.
fn fetch_image(settings: Settings, path: String) -> String {
  let fetched = case safe_media_path(path) {
    False -> Error("unexpected media path")
    True ->
      case
        web_fetch_get(
          join_bridge_url(settings.bridge_url, "/" <> path),
          inbound_media.max_bytes,
        )
      {
        Ok(#(200, bytes)) -> inbound_media.store(settings.data_dir, bytes)
        Ok(#(status, _)) -> Error("bridge answered " <> int.to_string(status))
        Error(_) -> Error("download failed")
      }
  }
  case fetched {
    Ok(id) -> {
      record.count("channel_media_total", [
        #("channel", "whatsapp"),
        #("outcome", "kept"),
      ])
      inbound_media.tag(id)
    }
    Error(reason) -> {
      record.count("channel_media_total", [
        #("channel", "whatsapp"),
        #("outcome", "failed"),
      ])
      io.println("warn: whatsapp image not kept: " <> reason)
      "\n[uma imagem que não consegui abrir]"
    }
  }
}

@external(erlang, "supernova_web_fetch_ffi", "get")
fn web_fetch_get(
  url: String,
  max_bytes: Int,
) -> Result(#(Int, BitArray), web.GetError)

/// A LID seen next to a phone becomes an alias of that phone's person
/// (PRD-I, I-04). Known LIDs are left alone.
fn learn_lid(data_dir: String, lid: String, phone: String) -> Nil {
  case aliases.resolve(lid) == lid {
    False -> Nil
    True ->
      case aliases.link(data_dir, lid, phone, "whatsapp", now_ms()) {
        Ok(Nil) -> record.count("whatsapp_lid_learned_total", [])
        Error(reason) ->
          io.println("warn: whatsapp LID not learned: " <> reason)
      }
  }
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

pub fn parse_event(
  event_json: String,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case json.parse(event_json, bridge_webhook_decoder()) {
    Ok(event) -> normalize_bridge_event(event)
    Error(_) ->
      case json.parse(event_json, whatsapp_webhook_decoder()) {
        Ok(event) -> normalize_cloud_event(event)
        Error(_) -> Error(port.SendFailed("invalid JSON"))
      }
  }
}

/// Build a deterministic send plan for the bridge transport.
pub fn build_send_plan(
  reply: port.ChannelReply,
) -> Result(BridgeRequestPlan, port.ChannelError) {
  let phone = normalise_chat_id(reply.channel_id)

  case reply.media {
    [first_media, ..] -> build_media_send_plan(phone, reply, first_media)
    [] -> build_text_send_plan(phone, reply)
  }
}

/// Serialize the logical bridge payload for debugging/tests.
pub fn build_reply_payload(
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  case build_send_plan(reply) {
    Ok(plan) -> Ok(encode_plan_preview(plan))
    Error(error) -> Error(error)
  }
}

pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  "whatsapp:" <> msg.channel_id <> ":" <> msg.user_id
}

pub fn session_resolver() -> SessionResolver {
  without_manager("whatsapp")
}

type WhatsAppBridgeWebhook {
  WhatsAppBridgeWebhook(
    event: String,
    device_id: Option(String),
    payload: WhatsAppBridgePayload,
  )
}

type WhatsAppBridgePayload {
  WhatsAppBridgePayload(
    id: String,
    chat_id: String,
    from: String,
    from_name: Option(String),
    is_from_me: Bool,
    body: Option(String),
    replied_to_id: Option(String),
    image: Option(BridgeMediaAttachment),
    audio: Option(BridgeMediaAttachment),
    document: Option(BridgeMediaAttachment),
  )
}

type BridgeMediaAttachment {
  BridgeMediaAttachment(caption: Option(String))
}

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

fn bridge_webhook_decoder() -> decode.Decoder(WhatsAppBridgeWebhook) {
  use event <- decode.field("event", decode.string)
  use device_id <- decode.optional_field(
    "device_id",
    None,
    decode.string |> decode.map(Some),
  )
  use payload <- decode.field("payload", bridge_payload_decoder())
  decode.success(WhatsAppBridgeWebhook(
    event: event,
    device_id: device_id,
    payload: payload,
  ))
}

fn bridge_payload_decoder() -> decode.Decoder(WhatsAppBridgePayload) {
  use id <- decode.field("id", decode.string)
  use chat_id <- decode.field("chat_id", decode.string)
  use from <- decode.field("from", decode.string)
  use from_name <- decode.optional_field(
    "from_name",
    None,
    decode.string |> decode.map(Some),
  )
  use is_from_me <- decode.optional_field("is_from_me", False, decode.bool)
  use body <- decode.optional_field(
    "body",
    None,
    decode.string |> decode.map(Some),
  )
  use replied_to_id <- decode.optional_field(
    "replied_to_id",
    None,
    decode.string |> decode.map(Some),
  )
  use image <- decode.optional_field(
    "image",
    None,
    bridge_media_attachment_decoder() |> decode.map(Some),
  )
  use audio <- decode.optional_field(
    "audio",
    None,
    bridge_media_attachment_decoder() |> decode.map(Some),
  )
  use document <- decode.optional_field(
    "document",
    None,
    bridge_media_attachment_decoder() |> decode.map(Some),
  )
  decode.success(WhatsAppBridgePayload(
    id: id,
    chat_id: chat_id,
    from: from,
    from_name: from_name,
    is_from_me: is_from_me,
    body: body,
    replied_to_id: replied_to_id,
    image: image,
    audio: audio,
    document: document,
  ))
}

fn bridge_media_attachment_decoder() -> decode.Decoder(BridgeMediaAttachment) {
  decode.one_of(
    decode.string |> decode.map(fn(_) { BridgeMediaAttachment(caption: None) }),
    or: [bridge_media_attachment_object_decoder()],
  )
}

fn bridge_media_attachment_object_decoder() -> decode.Decoder(
  BridgeMediaAttachment,
) {
  use caption <- decode.optional_field(
    "caption",
    None,
    decode.string |> decode.map(Some),
  )
  use _path <- decode.optional_field(
    "path",
    None,
    decode.string |> decode.map(Some),
  )
  use _url <- decode.optional_field(
    "url",
    None,
    decode.string |> decode.map(Some),
  )
  use _filename <- decode.optional_field(
    "filename",
    None,
    decode.string |> decode.map(Some),
  )
  decode.success(BridgeMediaAttachment(caption: caption))
}

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
  use messaging_product <- decode.optional_field(
    "messaging_product",
    None,
    decode.string |> decode.map(Some),
  )
  use metadata <- decode.optional_field(
    "metadata",
    None,
    whatsapp_metadata_decoder() |> decode.map(Some),
  )
  use contacts <- decode.optional_field(
    "contacts",
    None,
    decode.list(whatsapp_contact_decoder()) |> decode.map(Some),
  )
  use messages <- decode.optional_field(
    "messages",
    None,
    decode.list(whatsapp_message_decoder()) |> decode.map(Some),
  )
  use statuses <- decode.optional_field(
    "statuses",
    None,
    decode.list(whatsapp_status_decoder()) |> decode.map(Some),
  )
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
  use display_phone_number <- decode.field(
    "display_phone_number",
    decode.string,
  )
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
  use text <- decode.optional_field(
    "text",
    None,
    whatsapp_text_decoder() |> decode.map(Some),
  )
  use caption <- decode.optional_field(
    "caption",
    None,
    decode.string |> decode.map(Some),
  )
  use context <- decode.optional_field(
    "context",
    None,
    whatsapp_context_decoder() |> decode.map(Some),
  )
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

fn normalize_bridge_event(
  event: WhatsAppBridgeWebhook,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case event.event {
    "message" -> normalize_bridge_message(event.payload)
    other -> Error(port.Ignored("unsupported event: " <> other))
  }
}

fn normalize_bridge_message(
  payload: WhatsAppBridgePayload,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case payload.is_from_me {
    True -> Error(port.Ignored("bot sender filtered"))
    False -> {
      let content = bridge_payload_content(payload)
      case string.is_empty(content) {
        True -> Error(port.Ignored("empty content"))
        False ->
          Ok(port.ChannelMessage(
            id: payload.id,
            channel: "whatsapp",
            channel_id: payload.chat_id,
            user_id: payload.from,
            username: option_unwrap(payload.from_name, ""),
            content: content,
            is_bot: False,
            reply_to_id: payload.replied_to_id,
          ))
      }
    }
  }
}

fn bridge_payload_content(payload: WhatsAppBridgePayload) -> String {
  let body = option_unwrap(payload.body, "")
  case string.is_empty(body) {
    False -> body
    True -> {
      let media_caption =
        first_some([
          attachment_caption(payload.image),
          attachment_caption(payload.document),
          attachment_caption(payload.audio),
        ])
      option_unwrap(media_caption, "")
    }
  }
}

fn normalize_cloud_event(
  event: WhatsAppWebhook,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case event.entry {
    [first_entry, ..] -> {
      case first_entry.changes {
        [first_change, ..] -> normalize_cloud_value(first_change.value)
        _ -> Error(port.Ignored("no changes in entry"))
      }
    }
    _ -> Error(port.Ignored("no entries in webhook"))
  }
}

fn normalize_cloud_value(
  value: WhatsAppValue,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case value.metadata {
    Some(metadata) -> normalize_cloud_value_with_metadata(value, metadata)
    None -> Error(port.Ignored("missing metadata"))
  }
}

fn normalize_cloud_value_with_metadata(
  value: WhatsAppValue,
  metadata: WhatsAppMetadata,
) -> Result(port.ChannelMessage, port.ChannelError) {
  let username = case value.contacts {
    Some([first_contact, ..]) -> first_contact.profile.name
    _ -> ""
  }

  case value.messages {
    Some([first_message, ..]) ->
      normalize_cloud_message(first_message, metadata, username)
    Some([]) -> Error(port.Ignored("no messages in value"))
    None -> {
      case value.statuses {
        Some([first_status, ..]) ->
          Error(port.Ignored(
            "unsupported message type: " <> first_status.status,
          ))
        _ -> Error(port.Ignored("no messages in value"))
      }
    }
  }
}

fn normalize_cloud_message(
  msg: WhatsAppMessage,
  metadata: WhatsAppMetadata,
  username: String,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case
    msg.from == metadata.display_phone_number
    || msg.from == metadata.phone_number_id
  {
    True -> Error(port.Ignored("bot sender filtered"))
    False -> {
      let content = normalize_cloud_message_content(msg)
      case string.is_empty(content) {
        True -> Error(port.Ignored("empty content"))
        False -> {
          let reply_to = case msg.context {
            Some(ctx) -> Some(ctx.id)
            None -> None
          }

          let user_id = normalise_chat_id(msg.from)
          Ok(port.ChannelMessage(
            id: msg.id,
            channel: "whatsapp",
            channel_id: user_id,
            user_id: user_id,
            username: username,
            content: content,
            is_bot: False,
            reply_to_id: reply_to,
          ))
        }
      }
    }
  }
}

fn normalize_cloud_message_content(msg: WhatsAppMessage) -> String {
  case msg.msg_type {
    "text" ->
      case msg.text {
        Some(text) -> text.body
        None -> ""
      }
    "image" | "video" | "document" | "sticker" -> option_unwrap(msg.caption, "")
    _ -> ""
  }
}

fn build_text_send_plan(
  phone: String,
  reply: port.ChannelReply,
) -> Result(BridgeRequestPlan, port.ChannelError) {
  case string.is_empty(reply.content) {
    True -> Error(port.SendFailed("empty whatsapp message"))
    False ->
      Ok(BridgeRequestPlan(
        path: "/send/message",
        content_type: BridgeJson,
        fields: maybe_reply_field(
          [
            #("phone", phone),
            #("message", reply.content),
          ],
          reply.reply_to_id,
        ),
        download: None,
      ))
  }
}

fn build_media_send_plan(
  phone: String,
  reply: port.ChannelReply,
  media: port.ChannelMedia,
) -> Result(BridgeRequestPlan, port.ChannelError) {
  case media {
    port.ImageMedia(url, _) ->
      Ok(BridgeRequestPlan(
        path: "/send/image",
        content_type: BridgeMultipart,
        fields: image_fields(phone, reply.content, url),
        download: None,
      ))

    // A voice note the agent spoke (PRD-A, A-06): the file goes in the
    // body, and GOWA turns it into OGG/Opus (`ptt`).
    port.AudioMedia("file://" <> _ as url, mime) ->
      Ok(BridgeRequestPlan(
        path: "/send/audio",
        content_type: BridgeMultipart,
        fields: [#("phone", phone), #("ptt", "true")],
        download: Some(BridgeDownload(
          field_name: "audio",
          source_url: url,
          filename: "voz.wav",
          mime_type: mime,
        )),
      ))

    port.AudioMedia(url, _) ->
      Ok(BridgeRequestPlan(
        path: "/send/audio",
        content_type: BridgeMultipart,
        fields: [
          #("phone", phone),
          #("audio_url", url),
        ],
        download: None,
      ))

    port.DocumentMedia(url, filename, mime_type) ->
      Ok(BridgeRequestPlan(
        path: "/send/file",
        content_type: BridgeMultipart,
        fields: maybe_caption_field([#("phone", phone)], reply.content),
        download: Some(BridgeDownload(
          field_name: "file",
          source_url: url,
          filename: filename,
          mime_type: mime_type,
        )),
      ))
  }
}

fn maybe_reply_field(
  fields: List(#(String, String)),
  reply_to_id: Option(String),
) -> List(#(String, String)) {
  case reply_to_id {
    Some(message_id) -> append_field(fields, #("reply_message_id", message_id))
    None -> fields
  }
}

fn maybe_caption_field(
  fields: List(#(String, String)),
  caption: String,
) -> List(#(String, String)) {
  case string.is_empty(caption) {
    True -> fields
    False -> append_field(fields, #("caption", caption))
  }
}

fn image_fields(
  phone: String,
  caption: String,
  image_url: String,
) -> List(#(String, String)) {
  case string.is_empty(caption) {
    True -> [#("phone", phone), #("image_url", image_url)]
    False -> [
      #("phone", phone),
      #("caption", caption),
      #("image_url", image_url),
    ]
  }
}

fn do_send(
  settings: Settings,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  case local_files_allowed(settings, reply), build_send_plan(reply) {
    False, _ ->
      Error(port.SendFailed("local file outside the voice notes directory"))
    True, plan -> send_plan(settings, plan)
  }
}

/// A reply may carry a local file only from the voice notes directory: no
/// answer, not even one the model was led into, sends any other file.
fn local_files_allowed(settings: Settings, reply: port.ChannelReply) -> Bool {
  let allowed = voice.dir(settings.data_dir) <> "/"
  list.all(reply.media, fn(media) {
    let url = case media {
      port.ImageMedia(url, _) -> url
      port.AudioMedia(url, _) -> url
      port.DocumentMedia(url, _, _) -> url
    }
    case url {
      "file://" <> path ->
        string.starts_with(path, allowed) && !string.contains(path, "..")
      _ -> True
    }
  })
}

fn send_plan(
  settings: Settings,
  plan: Result(BridgeRequestPlan, port.ChannelError),
) -> Result(Nil, port.ChannelError) {
  case plan {
    Error(error) -> Error(error)
    Ok(plan) -> {
      let url = join_bridge_url(settings.bridge_url, plan.path)
      case request.to(url) {
        Error(_) -> Error(port.SendFailed("invalid bridge URL"))
        Ok(req) -> {
          let req =
            req
            |> request.set_method(http.Post)
            |> maybe_set_device_header(settings.device_id)
            |> request.set_header(
              "Authorization",
              basic_authorization(settings.basic_auth),
            )

          case plan.content_type {
            BridgeJson -> send_json_request(req, plan)
            BridgeMultipart -> send_multipart_request(req, plan)
          }
        }
      }
    }
  }
}

fn send_json_request(
  req: request.Request(String),
  plan: BridgeRequestPlan,
) -> Result(Nil, port.ChannelError) {
  let body = json.to_string(json_fields(plan.fields))

  let req =
    req
    |> request.set_header("Content-Type", "application/json")
    |> request.set_body(body)

  case hackney.send(req) {
    Ok(response) -> handle_bridge_response(response)
    Error(hackney.InvalidUtf8Response) ->
      Error(port.SendFailed("Invalid UTF-8 response from bridge"))
    Error(hackney.Other(reason)) ->
      Error(port.SendFailed("HTTP error: " <> string.inspect(reason)))
  }
}

fn send_multipart_request(
  req: request.Request(String),
  plan: BridgeRequestPlan,
) -> Result(Nil, port.ChannelError) {
  case multipart_body(plan, multipart_boundary) {
    Error(error) -> Error(error)
    Ok(body) -> {
      let req =
        req
        |> request.set_header(
          "Content-Type",
          "multipart/form-data; boundary=" <> multipart_boundary,
        )
        |> request.set_body(body)

      case hackney.send_bits(req) {
        Ok(response) -> handle_bridge_bits_response(response)
        Error(hackney.InvalidUtf8Response) ->
          Error(port.SendFailed("Invalid UTF-8 response from bridge"))
        Error(hackney.Other(reason)) ->
          Error(port.SendFailed("HTTP error: " <> string.inspect(reason)))
      }
    }
  }
}

fn multipart_body(
  plan: BridgeRequestPlan,
  boundary: String,
) -> Result(bytes_tree.BytesTree, port.ChannelError) {
  let field_parts =
    plan.fields
    |> list.map(fn(pair) {
      let #(name, value) = pair
      multipart_field(boundary, name, value)
    })

  case plan.download {
    Some(download) ->
      case download_remote_file(download.source_url) {
        Error(error) -> Error(error)
        Ok(file_bytes) -> {
          let parts =
            field_parts
            |> append_tree_part(multipart_download_part(
              boundary,
              download,
              file_bytes,
            ))
            |> append_tree_part(bytes_tree.from_string(
              "--" <> boundary <> "--\r\n",
            ))

          Ok(bytes_tree.concat(parts))
        }
      }
    None -> {
      let parts =
        field_parts
        |> append_tree_part(bytes_tree.from_string("--" <> boundary <> "--\r\n"))

      Ok(bytes_tree.concat(parts))
    }
  }
}

fn multipart_field(
  boundary: String,
  name: String,
  value: String,
) -> bytes_tree.BytesTree {
  bytes_tree.from_string(
    "--"
    <> boundary
    <> "\r\nContent-Disposition: form-data; name=\""
    <> name
    <> "\"\r\n\r\n"
    <> value
    <> "\r\n",
  )
}

fn multipart_download_part(
  boundary: String,
  download: BridgeDownload,
  file_bytes: BitArray,
) -> bytes_tree.BytesTree {
  let mime_type = option_unwrap(download.mime_type, default_file_mime_type)
  bytes_tree.concat([
    bytes_tree.from_string(
      "--"
      <> boundary
      <> "\r\nContent-Disposition: form-data; name=\""
      <> download.field_name
      <> "\"; filename=\""
      <> download.filename
      <> "\"\r\nContent-Type: "
      <> mime_type
      <> "\r\n\r\n",
    ),
    bytes_tree.from_bit_array(file_bytes),
    bytes_tree.from_string("\r\n"),
  ])
}

fn download_remote_file(
  source_url: String,
) -> Result(BitArray, port.ChannelError) {
  case source_url {
    // Checked by do_send: only the voice notes directory.
    "file://" <> path ->
      read_local(path)
      |> result.replace_error(port.SendFailed("voice note not readable"))
    _ -> download_http(source_url)
  }
}

@external(erlang, "file", "read_file")
fn read_local(path: String) -> Result(BitArray, decode.Dynamic)

fn download_http(source_url: String) -> Result(BitArray, port.ChannelError) {
  case request.to(source_url) {
    Error(_) -> Error(port.SendFailed("invalid media URL"))
    Ok(req) ->
      case req |> request.map(bytes_tree.from_string) |> hackney.send_bits {
        Ok(response) ->
          case response.status >= 200 && response.status < 300 {
            True -> Ok(response.body)
            False ->
              Error(port.SendFailed(
                "media download failed: " <> int.to_string(response.status),
              ))
          }
        Error(hackney.InvalidUtf8Response) ->
          Error(port.SendFailed("media download returned invalid UTF-8"))
        Error(hackney.Other(reason)) ->
          Error(port.SendFailed(
            "media download error: " <> string.inspect(reason),
          ))
      }
  }
}

/// The `Authorization` header for GOWA's basic auth (`user:password`).
pub fn basic_authorization(user_password: String) -> String {
  "Basic "
  <> bit_array.base64_encode(bit_array.from_string(user_password), True)
}

fn maybe_set_device_header(
  req: request.Request(String),
  device_id: Option(String),
) -> request.Request(String) {
  case device_id {
    Some(value) -> request.set_header(req, "X-Device-Id", value)
    None -> req
  }
}

fn join_bridge_url(base_url: String, path: String) -> String {
  case string.ends_with(base_url, "/") {
    True -> string.drop_end(base_url, 1) <> path
    False -> base_url <> path
  }
}

fn json_fields(fields: List(#(String, String))) -> json.Json {
  json.object(
    list.map(fields, fn(pair) {
      let #(key, value) = pair
      #(key, json.string(value))
    }),
  )
}

fn encode_plan_preview(plan: BridgeRequestPlan) -> String {
  let download_json = case plan.download {
    Some(download) ->
      json.object([
        #("field_name", json.string(download.field_name)),
        #("source_url", json.string(download.source_url)),
        #("filename", json.string(download.filename)),
        #(
          "mime_type",
          json.string(option_unwrap(download.mime_type, default_file_mime_type)),
        ),
      ])
    None -> json.null()
  }

  json.to_string(
    json.object([
      #("path", json.string(plan.path)),
      #(
        "content_type",
        json.string(case plan.content_type {
          BridgeJson -> "json"
          BridgeMultipart -> "multipart"
        }),
      ),
      #("fields", json_fields(plan.fields)),
      #("download", download_json),
    ]),
  )
}

fn handle_bridge_bits_response(
  response: Response(BitArray),
) -> Result(Nil, port.ChannelError) {
  let body = case bit_array.to_string(response.body) {
    Ok(value) -> value
    Error(_) -> ""
  }
  handle_bridge_response(set_body(response, body))
}

fn handle_bridge_response(
  response: Response(String),
) -> Result(Nil, port.ChannelError) {
  case response.status {
    200 | 201 -> Ok(Nil)
    400 -> Error(port.SendFailed("Bad request - invalid payload or chat_id"))
    401 | 403 ->
      Error(port.SendFailed("Unauthorized - check bridge credentials"))
    404 -> Error(port.SendFailed("Chat not found or session not ready"))
    429 -> {
      let retry_after = parse_bridge_retry_after(response.body)
      Error(port.RateLimited(retry_after_seconds: retry_after))
    }
    503 ->
      Error(port.SendFailed(
        "Bridge unavailable - WhatsApp session disconnected",
      ))
    status -> Error(port.SendFailed("Bridge error: " <> int.to_string(status)))
  }
}

fn parse_bridge_retry_after(body: String) -> Int {
  case
    json.parse(
      body,
      decode.field("retry_after", decode.int, fn(value) {
        decode.success(value)
      }),
    )
  {
    Ok(value) -> value
    Error(_) -> 30
  }
}

fn first_some(options: List(Option(Option(String)))) -> Option(String) {
  case options {
    [] -> None
    [first, ..rest] -> {
      case first {
        Some(Some(value)) -> Some(value)
        _ -> first_some(rest)
      }
    }
  }
}

fn attachment_caption(
  attachment: Option(BridgeMediaAttachment),
) -> Option(Option(String)) {
  case attachment {
    Some(media) -> Some(media.caption)
    None -> None
  }
}

fn append_field(
  fields: List(#(String, String)),
  field: #(String, String),
) -> List(#(String, String)) {
  list.reverse([field, ..list.reverse(fields)])
}

fn append_tree_part(
  parts: List(bytes_tree.BytesTree),
  part: bytes_tree.BytesTree,
) -> List(bytes_tree.BytesTree) {
  list.reverse([part, ..list.reverse(parts)])
}

fn option_unwrap(value: Option(a), default: a) -> a {
  case value {
    Some(inner) -> inner
    None -> default
  }
}

fn normalise_chat_id(value: String) -> String {
  case string.contains(value, "@") {
    True -> value
    False -> value <> "@s.whatsapp.net"
  }
}
