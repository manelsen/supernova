//// WhatsApp inbound — what Supernova makes of each GOWA webhook (PRD-C,
//// C-04; PRD-I, I-04). Pure apart from reading the alias table.
////
//// - A person is their phone: `from` `628…@s.whatsapp.net` gives the user
////   id `628…`. When the webhook also carries `from_lid`, the LID is
////   learned as an alias of the phone.
//// - A sender known only by LID (`…@lid`) is their person when the LID was
////   learned before; an unknown one is asked, in a group, to write in
////   private (where WhatsApp sends the phone), and only logged in private.
//// - In a group the agent answers what is addressed to it: a mention, a
////   reply to it, or a command; the rest is talk among the others.
//// - Own messages are dropped; account events become an alert.

import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port
import supernova/core/identity/aliases

pub type Decision {
  /// A message to answer; `learned` is a LID to link to the phone;
  /// `attachments` are the media GOWA downloaded (`statics/media/…`);
  /// `forwarded` says the person passed on someone else's message.
  Answer(
    message: port.ChannelMessage,
    learned: Option(#(String, String)),
    attachments: List(Attachment),
    forwarded: Bool,
  )
  /// A sender known only by an unknown LID wrote to the agent in a group.
  AskPrivate(chat_id: String, reply_to: String)
  Ignore(reason: String)
  /// The account was logged out (a new pairing is needed) or suspended
  /// (the session is kept until the suspension ends).
  AccountDown(reason: String, logged_out: Bool)
  Malformed
}

pub const ask_private_text =
  "Ainda não te reconheço por aqui. Me chama no privado?"

/// The large kinds of media (PRD-A).
pub type MediaKind {
  Image
  Audio
  Video
  Document
  Sticker
  AnimatedSticker
}

/// One medium of a message, as GOWA describes it.
pub type Attachment {
  Attachment(
    kind: MediaKind,
    /// GOWA's download (`statics/media/…`); None when it only has
    /// WhatsApp's encrypted URL.
    path: Option(String),
    seconds: Option(Int),
    file_name: Option(String),
    mime: Option(String),
    /// A voice note recorded in WhatsApp, not an audio file.
    voice_note: Bool,
  )
}

/// A note for a medium the agent cannot open yet, in the person's words.
pub fn unopened_note(attachment: Attachment, forwarded: Bool) -> String {
  let length = case attachment.seconds {
    Some(seconds) -> " de " <> duration(seconds)
    None -> ""
  }
  let passed_on = case forwarded {
    True -> " encaminhado"
    False -> ""
  }
  case attachment.kind {
    Audio ->
      case attachment.voice_note {
        True ->
          "[uma mensagem de voz"
          <> passed_on
          <> length
          <> ", que ainda não consigo ouvir]"
        False ->
          "[um áudio" <> passed_on <> length <> ", que ainda não consigo ouvir]"
      }
    Video ->
      "[um vídeo" <> passed_on <> length <> ", que ainda não consigo ver]"
    Document ->
      "[um documento"
      <> passed_on
      <> case attachment.file_name {
        Some(name) -> " (" <> name <> ")"
        None -> ""
      }
      <> ", que ainda não consigo ler]"
    AnimatedSticker -> "[uma figurinha animada]"
    Image | Sticker -> "[uma imagem que não consegui abrir]"
  }
}

/// `0:42`, `1:10`, `1:02:03`.
pub fn duration(seconds: Int) -> String {
  let pad = fn(n) { string.pad_start(int.to_string(n), 2, "0") }
  case seconds >= 3600 {
    True ->
      int.to_string(seconds / 3600)
      <> ":"
      <> pad(seconds % 3600 / 60)
      <> ":"
      <> pad(seconds % 60)
    False -> int.to_string(seconds / 60) <> ":" <> pad(seconds % 60)
  }
}

type Envelope {
  Envelope(event: String, device_id: String, payload: decode.Dynamic)
}

type Message {
  Message(
    id: String,
    chat_id: String,
    from: String,
    from_lid: Option(String),
    from_name: Option(String),
    is_from_me: Bool,
    body: String,
    replied_to_id: Option(String),
    replied_to_sender: Option(String),
    mentions: List(String),
    media: List(#(MediaKind, Medium)),
    info: Info,
    forwarded: Bool,
    notes: List(String),
  )
}

type Medium {
  Medium(
    path: Option(String),
    caption: Option(String),
    file_name: Option(String),
  )
}

type Info {
  Info(
    seconds: Option(Int),
    mime: Option(String),
    file_name: Option(String),
    voice_note: Bool,
    animated: Bool,
  )
}

/// What to do with a webhook, with groups off: every group message is
/// dropped unread (the maintainer's rule for now: all conversations in
/// private).
pub fn decide(body: String) -> Decision {
  decide_with(body, False)
}

/// `decide` with groups on (`whatsapp.allow_groups`): in a group the agent
/// answers a mention, a reply to it, or a command.
pub fn decide_allowing_groups(body: String) -> Decision {
  decide_with(body, True)
}

fn decide_with(body: String, allow_groups: Bool) -> Decision {
  case json.parse(body, envelope_decoder()) {
    Error(_) -> Malformed
    Ok(envelope) ->
      case envelope.event {
        "message" ->
          case decode.run(envelope.payload, message_decoder()) {
            Ok(message) ->
              case allow_groups, string.ends_with(message.chat_id, "@g.us") {
                False, True -> Ignore("groups are off")
                _, _ -> decide_message(envelope.device_id, message)
              }
            Error(_) -> Malformed
          }
        "device.logged_out" ->
          case decode.run(envelope.payload, account_decoder()) {
            Ok(#(code, reason, _)) ->
              AccountDown(
                "a conta foi desconectada ("
                  <> int.to_string(code)
                  <> ": "
                  <> reason
                  <> ")",
                logged_out: True,
              )
            Error(_) ->
              AccountDown("a conta foi desconectada", logged_out: True)
          }
        "device.temporary_ban" ->
          case decode.run(envelope.payload, account_decoder()) {
            Ok(#(code, reason, until)) ->
              AccountDown(
                "suspensão temporária"
                  <> case until {
                  Some(at) -> " até " <> at
                  None -> ""
                }
                  <> " ("
                  <> int.to_string(code)
                  <> ": "
                  <> reason
                  <> ")",
                logged_out: False,
              )
            Error(_) -> AccountDown("suspensão temporária", logged_out: False)
          }
        other -> Ignore("event " <> other)
      }
  }
}

fn decide_message(agent: String, message: Message) -> Decision {
  let caption =
    list.find_map(message.media, fn(pair) {
      let #(_, medium) = pair
      option.to_result(medium.caption, Nil)
    })
    |> option.from_result
  let said = case message.body {
    "" -> option.unwrap(caption, "")
    text -> text
  }
  let content = case said, message.notes {
    _, [] -> said
    "", notes -> string.join(notes, "\n")
    text, notes -> text <> "\n" <> string.join(notes, "\n")
  }
  let attachments =
    list.map(message.media, fn(pair) {
      let #(kind, medium) = pair
      let kind = case kind, message.info.animated {
        Sticker, True -> AnimatedSticker
        kind, _ -> kind
      }
      Attachment(
        kind: kind,
        path: medium.path,
        seconds: message.info.seconds,
        file_name: option.or(medium.file_name, message.info.file_name),
        mime: message.info.mime,
        voice_note: message.info.voice_note,
      )
    })
  let in_group = string.ends_with(message.chat_id, "@g.us")
  let addressed =
    !in_group
    || list.contains(message.mentions, agent)
    || message.replied_to_sender == Some(agent)
    || string.starts_with(string.trim(content), "/")
  let empty = string.trim(content) == "" && attachments == []
  case message.is_from_me, empty, addressed {
    True, _, _ -> Ignore("own message")
    _, True, _ -> Ignore("empty message")
    _, _, False -> Ignore("group talk not addressed to the agent")
    False, False, True ->
      case sender(message) {
        Phone(phone) ->
          Answer(
            to_channel_message(message, phone, content),
            learned: option.map(message.from_lid, fn(lid) {
              #("whatsapp:" <> lid, "whatsapp:" <> phone)
            }),
            attachments: attachments,
            forwarded: message.forwarded,
          )
        Lid(lid) ->
          case aliases.resolve("whatsapp:" <> lid) == "whatsapp:" <> lid {
            False ->
              Answer(
                to_channel_message(message, lid, content),
                learned: None,
                attachments: attachments,
                forwarded: message.forwarded,
              )
            True ->
              case in_group {
                True -> AskPrivate(message.chat_id, message.id)
                False -> Ignore("unknown lid")
              }
          }
        Unknown -> Ignore("sender without phone or lid")
      }
  }
}

type Sender {
  Phone(String)
  Lid(String)
  Unknown
}

fn sender(message: Message) -> Sender {
  case string.split_once(message.from, "@") {
    Ok(#(phone, "s.whatsapp.net")) if phone != "" -> Phone(phone)
    Ok(#(id, "lid")) if id != "" -> Lid(message.from)
    _ -> Unknown
  }
}

fn to_channel_message(
  message: Message,
  user_id: String,
  content: String,
) -> port.ChannelMessage {
  port.ChannelMessage(
    id: message.id,
    channel: "whatsapp",
    channel_id: message.chat_id,
    user_id: user_id,
    username: option.unwrap(message.from_name, ""),
    content: content,
    is_bot: False,
    reply_to_id: message.replied_to_id,
  )
}

fn envelope_decoder() -> decode.Decoder(Envelope) {
  use event <- decode.field("event", decode.string)
  use device_id <- decode.optional_field("device_id", "", decode.string)
  use payload <- decode.optional_field(
    "payload",
    decode_nothing(),
    decode.dynamic,
  )
  decode.success(Envelope(event, device_id, payload))
}

fn decode_nothing() -> decode.Dynamic {
  let assert Ok(nothing) = json.parse("null", decode.dynamic)
  nothing
}

fn optional_string(name: String, next) {
  decode.optional_field(name, None, decode.optional(decode.string), next)
}

fn message_decoder() -> decode.Decoder(Message) {
  use id <- decode.field("id", decode.string)
  use chat_id <- decode.field("chat_id", decode.string)
  use from <- decode.optional_field("from", "", decode.string)
  use from_lid <- optional_string("from_lid")
  use from_name <- optional_string("from_name")
  use is_from_me <- decode.optional_field("is_from_me", False, decode.bool)
  use body <- decode.optional_field("body", "", decode.string)
  use replied_to_id <- optional_string("replied_to_id")
  use replied_to_sender <- optional_string("replied_to_sender")
  use mentions <- decode.optional_field(
    "mentions",
    [],
    decode.list(decode.string),
  )
  let medium = fn(key, kind, next) {
    decode.optional_field(key, None, medium_decoder(kind), next)
  }
  use image <- medium("image", Image)
  use audio <- medium("audio", Audio)
  use video <- medium("video", Video)
  use video_note <- medium("video_note", Video)
  use document <- medium("document", Document)
  use sticker <- medium("sticker", Sticker)
  use info <- decode.optional_field(
    "media_info",
    Info(None, None, None, False, False),
    info_decoder(),
  )
  use forwarded <- decode.optional_field("forwarded", False, decode.bool)
  use location <- decode.optional_field(
    "location",
    None,
    decode.map(location_decoder("localização"), Some),
  )
  use live_location <- decode.optional_field(
    "live_location",
    None,
    decode.map(location_decoder("localização em tempo real"), Some),
  )
  use contact <- decode.optional_field(
    "contact",
    None,
    decode.map(contact_decoder(), Some),
  )
  use contacts <- decode.optional_field(
    "contacts_array",
    [],
    decode.list(contact_decoder()),
  )
  use poll <- decode.optional_field(
    "poll",
    None,
    decode.map(poll_decoder(), Some),
  )
  let media =
    [image, audio, video, video_note, document, sticker]
    |> option.values
  let notes =
    list.flatten([
      option.values([location, live_location, contact]),
      contacts,
      option.values([poll]) |> list.filter(fn(note) { note != "" }),
    ])
  decode.success(Message(
    id:,
    chat_id:,
    from:,
    from_lid:,
    from_name:,
    is_from_me:,
    body:,
    replied_to_id:,
    replied_to_sender:,
    mentions:,
    media:,
    info:,
    forwarded:,
    notes:,
  ))
}

/// A medium is a path (downloaded, no caption) or an object with `path`
/// (downloaded) or `url` (not downloaded: WhatsApp's encrypted URL, of no
/// use here), maybe a caption and, for documents, `filename`.
fn medium_decoder(
  kind: MediaKind,
) -> decode.Decoder(Option(#(MediaKind, Medium))) {
  decode.one_of(
    decode.string
      |> decode.map(fn(path) { Some(#(kind, Medium(Some(path), None, None))) }),
    [
      {
        use path <- optional_string("path")
        use caption <- optional_string("caption")
        use file_name <- optional_string("filename")
        decode.success(Some(#(kind, Medium(path, caption, file_name))))
      },
    ],
  )
}

fn info_decoder() -> decode.Decoder(Info) {
  use seconds <- decode.optional_field(
    "seconds",
    None,
    decode.optional(decode.int),
  )
  use mime <- optional_string("mime_type")
  use file_name <- optional_string("file_name")
  use voice_note <- decode.optional_field("ptt", False, decode.bool)
  use animated <- decode.optional_field("is_animated", False, decode.bool)
  decode.success(Info(seconds, mime, file_name, voice_note, animated))
}

fn number() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn location_decoder(label: String) -> decode.Decoder(String) {
  use latitude <- decode.field("degreesLatitude", number())
  use longitude <- decode.field("degreesLongitude", number())
  use name <- decode.optional_field("name", "", decode.string)
  use address <- decode.optional_field("address", "", decode.string)
  let place =
    [name, address]
    |> list.filter(fn(part) { part != "" })
    |> string.join(", ")
  let point =
    "("
    <> float.to_string(latitude)
    <> ", "
    <> float.to_string(longitude)
    <> ")"
  decode.success(case place {
    "" -> "[" <> label <> ": " <> point <> "]"
    _ -> "[" <> label <> ": " <> place <> " " <> point <> "]"
  })
}

fn contact_decoder() -> decode.Decoder(String) {
  use name <- decode.optional_field("displayName", "", decode.string)
  use phone <- decode.optional_field("phone_number", "", decode.string)
  decode.success(
    "["
    <> "contato: "
    <> [name, phone]
    |> list.filter(fn(part) { part != "" })
    |> string.join(", ")
    <> "]",
  )
}

/// A poll the person created becomes its question and options; votes and
/// edits carry no text of their own here.
fn poll_decoder() -> decode.Decoder(String) {
  use kind <- decode.optional_field("type", "", decode.string)
  use question <- decode.optional_field("question", "", decode.string)
  use options <- decode.optional_field(
    "options",
    [],
    decode.list({
      use name <- decode.optional_field("name", "", decode.string)
      decode.success(name)
    }),
  )
  decode.success(case kind {
    "creation" ->
      "[enquete: " <> question <> " (" <> string.join(options, "; ") <> ")]"
    _ -> ""
  })
}

fn account_decoder() -> decode.Decoder(#(Int, String, Option(String))) {
  use code <- decode.optional_field("code", 0, decode.int)
  use reason <- decode.optional_field("reason", "", decode.string)
  use until <- optional_string("expires_at")
  decode.success(#(code, reason, until))
}
