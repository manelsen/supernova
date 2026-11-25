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
  type Kind, type Media, Audio, Document, Image, Video,
}
import supernova/channel/port
import supernova/core/access/actor as access_actor
import supernova/core/access/types as access_types
import supernova/core/agent_identity
import supernova/core/closed_group/global as closed_group_global
import supernova/core/media_prompts

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

pub type Settings {
  Settings(
    data_dir: String,
    reader: Reader,
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
  case inbound {
    port.InboundInteraction(_) -> inbound
    port.InboundMessage(message) ->
      case non_image_refs(message.content), closed_group_global.get_config() {
        False, _ | _, None -> inbound
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
                admit: fn(_, _) { Error(Nil) },
                audio: False,
                video: False,
                document: False,
              )
          }
          port.InboundMessage(
            port.ChannelMessage(
              ..message,
              content: prepare(settings, principal, message.content),
            ),
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

/// The content with every audio, video and document tag turned into text.
pub fn prepare(
  settings: Settings,
  principal: String,
  content: String,
) -> String {
  inbound_media.refs(content)
  |> list.fold(content, fn(content, ref) {
    let #(kind, id) = ref
    case kind, inbound_media.load(settings.data_dir, id) {
      Image, _ -> content
      _, Error(Nil) -> content
      _, Ok(media) ->
        string.replace(
          content,
          inbound_media.tag_for(media),
          "\n" <> read_one(settings, principal, media),
        )
    }
  })
}

fn read_one(settings: Settings, principal: String, media: Media) -> String {
  let on = case media.kind {
    Audio -> settings.audio
    Video -> settings.video
    Document -> settings.document
    Image -> False
  }
  let text = case on {
    False -> unopened(media)
    True ->
      case
        settings.admit(
          principal,
          estimate_tokens(media.kind, media.seconds, media.size),
        )
      {
        Error(Nil) -> failed(media, "o limite de gasto do dia foi atingido")
        Ok(settle) -> {
          let #(instruction, start, end) = instruction(media.kind)
          case
            settings.reader(
              inbound_media.file_path(settings.data_dir, media.id),
              media.mime,
              media.size,
              instruction,
            )
          {
            Ok(read) -> {
              settle(read.input_tokens, read.output_tokens)
              heading(media)
              <> "\n"
              <> media_prompts.strip_markers(read.text, start, end)
            }
            Error(reason) -> {
              settle(0, 0)
              failed(media, reason)
            }
          }
        }
      }
  }
  inbound_media.discard(settings.data_dir, media.id)
  text
}

fn instruction(kind: Kind) -> #(String, String, String) {
  case kind {
    Audio -> #(
      media_prompts.audio(),
      media_prompts.audio_start,
      media_prompts.audio_end,
    )
    Video -> #(
      media_prompts.video(),
      media_prompts.video_start,
      media_prompts.video_end,
    )
    _ -> #(
      media_prompts.document(),
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
    _, _, False -> "documento" <> named(media)
    _, _, True -> "documento encaminhado" <> named(media)
  }
}

fn article(media: Media) -> String {
  case media.kind, media.voice_note {
    Audio, True -> "uma "
    _, _ -> "um "
  }
}

fn heading(media: Media) -> String {
  let done = case media.kind, media.voice_note {
    Audio, True -> "transcrita"
    Audio, False -> "transcrito"
    Video, _ -> "descrito"
    _, _ -> "lido"
  }
  "[" <> what(media) <> ", " <> done <> "]"
}

fn verb(media: Media) -> String {
  case media.kind {
    Audio -> "ouvir"
    Video -> "ver"
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
