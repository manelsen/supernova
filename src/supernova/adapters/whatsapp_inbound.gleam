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
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port
import supernova/core/identity/aliases

pub type Decision {
  /// A message to answer; `learned` is a LID to link to the phone;
  /// `image` is the path of an image GOWA downloaded (`statics/media/…`).
  Answer(
    message: port.ChannelMessage,
    learned: Option(#(String, String)),
    image: Option(String),
  )
  /// A sender known only by an unknown LID wrote to the agent in a group.
  AskPrivate(chat_id: String, reply_to: String)
  Ignore(reason: String)
  /// The account was logged out or suspended.
  AccountDown(reason: String)
  Malformed
}

pub const ask_private_text =
  "Ainda não te reconheço por aqui. Me chama no privado?"

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
    image: Option(Image),
  )
}

type Image {
  Image(path: Option(String), caption: Option(String))
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
              )
            Error(_) -> AccountDown("a conta foi desconectada")
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
              )
            Error(_) -> AccountDown("suspensão temporária")
          }
        other -> Ignore("event " <> other)
      }
  }
}

fn decide_message(agent: String, message: Message) -> Decision {
  let caption = option.then(message.image, fn(image) { image.caption })
  let image_path = option.then(message.image, fn(image) { image.path })
  let content = case message.body {
    "" -> option.unwrap(caption, "")
    text -> text
  }
  let in_group = string.ends_with(message.chat_id, "@g.us")
  let addressed =
    !in_group
    || list.contains(message.mentions, agent)
    || message.replied_to_sender == Some(agent)
    || string.starts_with(string.trim(content), "/")
  let empty = string.trim(content) == "" && image_path == None
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
            image: image_path,
          )
        Lid(lid) ->
          case aliases.resolve("whatsapp:" <> lid) == "whatsapp:" <> lid {
            False ->
              Answer(
                to_channel_message(message, lid, content),
                learned: None,
                image: image_path,
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
  use image <- decode.optional_field("image", None, image_decoder())
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
    image:,
  ))
}

/// An image is a path (downloaded, no caption) or an object with `path`
/// (downloaded) or `url` (not downloaded: WhatsApp's encrypted URL, of no
/// use here), and maybe a caption.
fn image_decoder() -> decode.Decoder(Option(Image)) {
  decode.one_of(
    decode.string |> decode.map(fn(path) { Some(Image(Some(path), None)) }),
    [
      {
        use path <- optional_string("path")
        use caption <- optional_string("caption")
        decode.success(Some(Image(path, caption)))
      },
    ],
  )
}

fn account_decoder() -> decode.Decoder(#(Int, String, Option(String))) {
  use code <- decode.optional_field("code", 0, decode.int)
  use reason <- decode.optional_field("reason", "", decode.string)
  use until <- optional_string("expires_at")
  decode.success(#(code, reason, until))
}
