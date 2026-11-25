//// Reading media before the turn (PRD-A, A-04; D1, D4). Each audio, video
//// and document the person sent becomes text: a literal transcription, an
//// audio description with the speech transcribed, the document's content.
//// The text takes the tag's place, so the turn, the history, the memory,
//// `buscar_conversa` and `/esquecer` all deal with text. Images are left
//// to the turn (the agent's model sees them).
////
//// Every reading is admitted in the ledger first and charged to the
//// person; a kind turned off, a denied budget or a failed reading becomes
//// a note the agent can answer, never silence. The file is deleted once
//// read.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/inbound_media.{
  type Kind, type Media, Audio, Document, Image, Sticker, Video,
}
import supernova/channel/port
import supernova/core/access/actor as access_actor
import supernova/core/access/types as access_types
import supernova/core/agent_identity
import supernova/core/closed_group/global as closed_group_global
import supernova/core/media_prompts
import supernova/core/preferences

/// What a reader made of a medium, and what it cost in tokens.
pub type Read {
  Read(text: String, input_tokens: Int, output_tokens: Int)
}

/// Reads a medium on disk: path, MIME type, size, instruction.
pub type Reader =
  fn(String, String, Int, String) -> Result(Read, String)

/// Admits a paid reading for a person, estimated in input tokens; the
/// result settles it with the tokens spent (0, 0 releases it).
pub type Admit =
  fn(String, Int) -> Result(fn(Int, Int) -> Nil, Nil)

/// Splits an animated sticker into frames on disk (A-10): the frames'
/// paths, in order.
pub type Frames =
  fn(String) -> Result(List(String), String)

/// Reads frames, in order, with an instruction.
pub type FramesReader =
  fn(List(String), String) -> Result(Read, String)

pub type Settings {
  Settings(
    data_dir: String,
    reader: Reader,
    frames: Frames,
    frames_reader: FramesReader,
    admit: Admit,
    audio: Bool,
    video: Bool,
    document: Bool,
  )
}

const key = "supernova_media_reading"

@external(erlang, "supernova_global_ffi", "global_put")
fn put(key: String, settings: Option(Settings)) -> Nil

@external(erlang, "supernova_tool_limits_ffi", "get")
fn get(key: String) -> Result(Option(Settings), Nil)

/// The reader every turn uses (boot).
pub fn configure(settings: Settings) -> Nil {
  put(key, Some(settings))
}

/// No reader: media become notes.
pub fn clear() -> Nil {
  put(key, None)
}

pub fn current() -> Option(Settings) {
  case get(key) {
    Ok(settings) -> settings
    Error(Nil) -> None
  }
}

/// The inbound with its media read, at the start of the turn (in the
/// chat's lane, after the message is in the inbox). A paid reading only
/// for a person with access: a stranger's video costs nothing, and the
/// gate answers them as usual.
pub fn prepare_inbound(inbound: port.ChannelInbound) -> port.ChannelInbound {
  read_inbound(inbound).0
}

/// Marks a message that only carried forwarded audio: the router answers
/// it with the transcription, without the model (PRD-A, D6). It starts
/// with an invisible separator, so a person cannot type it by accident.
pub const forwarded_marker = "\u{2063}[transcrição encaminhada]\n"

/// The turn's inbound with its media read, and the transcriptions D6 asks
/// for:
/// - a message with only forwarded audio becomes the transcription,
///   marked for the router to answer without the model;
/// - with `/transcricao`, the person's own audio comes back transcribed
///   before the agent's answer, through `send`.
pub fn prepare_turn(
  inbound: port.ChannelInbound,
  send: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
) -> port.ChannelInbound {
  case inbound, read_inbound(inbound) {
    port.InboundMessage(original), #(port.InboundMessage(read), readings) -> {
      let audio = list.filter(readings, fn(r) { r.kind == Audio })
      let forwarded = list.filter(audio, fn(r) { r.forwarded })
      let own = list.filter(audio, fn(r) { !r.forwarded })
      case only_media(original.content), forwarded, readings == forwarded {
        True, [_, ..], True ->
          port.InboundMessage(
            port.ChannelMessage(
              ..read,
              content: forwarded_marker <> transcript_reply(forwarded),
            ),
          )
        _, _, _ -> {
          case own, wants_transcription(original) {
            [_, ..], True -> {
              let _ =
                send(port.reply(to: original, content: transcript_reply(own)))
              Nil
            }
            _, _ -> Nil
          }
          port.InboundMessage(read)
        }
      }
    }
    _, #(read, _) -> read
  }
}

/// The transcription as Amélie gives it: easy to find and to read with a
/// screen reader.
pub fn transcript_reply(readings: List(Reading)) -> String {
  readings
  |> list.map(fn(r) {
    media_prompts.audio_start
    <> "\n"
    <> r.text
    <> "\n"
    <> media_prompts.audio_end
  })
  |> string.join("\n\n")
}

/// True when the message had media and nothing else to say.
fn only_media(content: String) -> Bool {
  let #(text, refs) = inbound_media.parse(content)
  refs != []
  && list.fold(
    ["[imagem]", "[áudio]", "[vídeo]", "[documento]", "[figurinha]"],
    text,
    fn(t, p) { string.replace(t, p, "") },
  )
  |> string.trim
  == ""
}

fn wants_transcription(message: port.ChannelMessage) -> Bool {
  case closed_group_global.get_config() {
    None -> False
    Some(cfg) ->
      preferences.load(
        cfg.data_dir,
        agent_identity.principal_id(message.channel, message.user_id),
      ).transcription
  }
}

fn read_inbound(
  inbound: port.ChannelInbound,
) -> #(port.ChannelInbound, List(Reading)) {
  case inbound {
    port.InboundInteraction(_) -> #(inbound, [])
    port.InboundMessage(message) ->
      case non_image_refs(message.content), closed_group_global.get_config() {
        False, _ | _, None -> #(inbound, [])
        True, Some(cfg) -> {
          let principal =
            agent_identity.principal_id(message.channel, message.user_id)
          let settings = case current(), has_access(principal) {
            Some(settings), True -> settings
            // No reader, or no access: notes only, nothing spent.
            _, _ ->
              Settings(
                data_dir: cfg.data_dir,
                reader: fn(_, _, _, _) { Error("no reader") },
                frames: fn(_) { Error("no reader") },
                frames_reader: fn(_, _) { Error("no reader") },
                admit: fn(_, _) { Error(Nil) },
                audio: False,
                video: False,
                document: False,
              )
          }
          let #(content, readings) =
            read_all(settings, principal, message.content)
          #(
            port.InboundMessage(
              port.ChannelMessage(..message, content: content),
            ),
            readings,
          )
        }
      }
  }
}

fn non_image_refs(content: String) -> Bool {
  inbound_media.refs(content)
  |> list.any(fn(ref) { ref.0 != Image })
}

fn has_access(principal: String) -> Bool {
  case closed_group_global.get_runtime() {
    None -> False
    Some(runtime) ->
      case access_actor.try_check(runtime.access, principal) {
        Ok(access_types.Allowed(_)) -> True
        _ -> False
      }
  }
}

/// What was read from one medium.
pub type Reading {
  Reading(kind: Kind, forwarded: Bool, voice_note: Bool, text: String)
}

/// The content with every audio, video and document tag turned into text.
pub fn prepare(
  settings: Settings,
  principal: String,
  content: String,
) -> String {
  read_all(settings, principal, content).0
}

/// `prepare`, and what was read (only the readings that succeeded).
pub fn read_all(
  settings: Settings,
  principal: String,
  content: String,
) -> #(String, List(Reading)) {
  inbound_media.refs(content)
  |> list.fold(#(content, []), fn(acc, ref) {
    let #(content, readings) = acc
    let #(kind, id) = ref
    case kind, inbound_media.load(settings.data_dir, id) {
      Image, _ -> acc
      _, Error(Nil) -> acc
      _, Ok(media) -> {
        let detail = preferences.load(settings.data_dir, principal).detail
        let #(text, reading) = read_one(settings, principal, media, detail)
        #(
          string.replace(content, inbound_media.tag_for(media), "\n" <> text),
          case reading {
            Some(reading) -> list.append(readings, [reading])
            None -> readings
          },
        )
      }
    }
  })
}

fn read_one(
  settings: Settings,
  principal: String,
  media: Media,
  detail: preferences.Detail,
) -> #(String, Option(Reading)) {
  let on = case media.kind {
    Audio -> settings.audio
    // Stickers move like videos: read when videos are.
    Video | Sticker -> settings.video
    Document -> settings.document
    Image -> False
  }
  let result = case on {
    False -> #(unopened(media), None)
    True ->
      case
        settings.admit(
          principal,
          estimate_tokens(media.kind, media.seconds, media.size),
        )
      {
        Error(Nil) -> #(
          failed(media, "o limite de gasto do dia foi atingido"),
          None,
        )
        Ok(settle) -> {
          let #(instruction, start, end) = instruction(media.kind, detail)
          let path = inbound_media.file_path(settings.data_dir, media.id)
          let reading = case media.kind {
            Sticker ->
              case settings.frames(path) {
                Ok(frames) -> settings.frames_reader(frames, instruction)
                Error(reason) -> Error(reason)
              }
            _ -> settings.reader(path, media.mime, media.size, instruction)
          }
          case reading {
            Ok(read) -> {
              settle(read.input_tokens, read.output_tokens)
              let text = media_prompts.strip_markers(read.text, start, end)
              #(
                heading(media) <> "\n" <> text,
                Some(Reading(
                  kind: media.kind,
                  forwarded: media.forwarded,
                  voice_note: media.voice_note,
                  text: text,
                )),
              )
            }
            Error(reason) -> {
              settle(0, 0)
              #(failed(media, reason), None)
            }
          }
        }
      }
  }
  inbound_media.discard(settings.data_dir, media.id)
  result
}

fn instruction(
  kind: Kind,
  detail: preferences.Detail,
) -> #(String, String, String) {
  case kind {
    Audio -> #(
      media_prompts.audio(),
      media_prompts.audio_start,
      media_prompts.audio_end,
    )
    Video -> #(
      media_prompts.video_with(detail),
      media_prompts.video_start,
      media_prompts.video_end,
    )
    Sticker -> #(
      media_prompts.animated_sticker_with(detail),
      media_prompts.sticker_start,
      media_prompts.sticker_end,
    )
    _ -> #(
      media_prompts.document_with(detail),
      media_prompts.document_start,
      media_prompts.document_end,
    )
  }
}

/// Input tokens of a reading, by the documented rates, plus room for the
/// answer: 25 per second of audio; about 100 per second of video (one
/// frame a second and its sound); about 560 per page of a document, the
/// pages guessed from the size (30 KB a page).
pub fn estimate_tokens(kind: Kind, seconds: Option(Int), size: Int) -> Int {
  let answer = 2000
  case kind {
    Audio -> 25 * option.unwrap(seconds, size / 2000) + answer
    Video -> 100 * option.unwrap(seconds, size / 250_000) + answer
    // Up to eight frames, about 1120 tokens each.
    Sticker -> 8 * 1120 + answer
    _ -> 560 * int.max(1, size / 30_000) + answer
  }
}

fn length(media: Media) -> String {
  case media.seconds {
    Some(seconds) -> " de " <> duration(seconds)
    None -> ""
  }
}

fn duration(seconds: Int) -> String {
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

fn named(media: Media) -> String {
  case media.file_name {
    Some(name) -> " (" <> name <> ")"
    None -> ""
  }
}

/// `mensagem de voz de 0:42`, `vídeo encaminhado de 1:10`.
fn what(media: Media) -> String {
  case media.kind, media.voice_note, media.forwarded {
    Audio, True, False -> "mensagem de voz" <> length(media)
    Audio, True, True -> "mensagem de voz encaminhada" <> length(media)
    Audio, False, False -> "áudio" <> length(media)
    Audio, False, True -> "áudio encaminhado" <> length(media)
    Video, _, False -> "vídeo" <> length(media)
    Video, _, True -> "vídeo encaminhado" <> length(media)
    Sticker, _, False -> "figurinha animada"
    Sticker, _, True -> "figurinha animada encaminhada"
    _, _, False -> "documento" <> named(media)
    _, _, True -> "documento encaminhado" <> named(media)
  }
}

fn article(media: Media) -> String {
  case media.kind, media.voice_note {
    Audio, True | Sticker, _ -> "uma "
    _, _ -> "um "
  }
}

fn heading(media: Media) -> String {
  let done = case media.kind, media.voice_note {
    Audio, True -> "transcrita"
    Audio, False -> "transcrito"
    Video, _ -> "descrito"
    Sticker, _ -> "descrita"
    _, _ -> "lido"
  }
  "[" <> what(media) <> ", " <> done <> "]"
}

fn verb(media: Media) -> String {
  case media.kind {
    Audio -> "ouvir"
    Video | Sticker -> "ver"
    _ -> "ler"
  }
}

fn unopened(media: Media) -> String {
  "["
  <> article(media)
  <> what(media)
  <> ", que ainda não consigo "
  <> verb(media)
  <> "]"
}

fn failed(media: Media, reason: String) -> String {
  "["
  <> article(media)
  <> what(media)
  <> " que não consegui "
  <> verb(media)
  <> ": "
  <> reason
  <> "]"
}
