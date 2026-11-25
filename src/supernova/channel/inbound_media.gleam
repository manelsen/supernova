//// Media a person sends (PRD-C, C-05). The capability every channel uses:
//// a size limit, a type policy, a temporary file.
////
//// The channel stores the file and appends `[imagem:<id>]` to the message
//// text: the text stays small in the inbox, the history and the memory.
//// When the turn's messages are built, the tag becomes an image for the
//// model and the file is deleted (`take_data_url`); the history keeps
//// `[imagem]`. Files of turns that never ran are swept at boot.
////
//// Images only for now (JPEG, PNG, GIF, WebP, checked by their bytes);
//// audio and documents come later on the same capability.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Largest file kept, in bytes.
pub const max_bytes = 5_242_880

/// Files older than this are swept at boot, in milliseconds.
pub const max_age_ms = 86_400_000

const open = "[imagem:"

@external(erlang, "supernova_inbound_media_ffi", "write")
fn write(path: String, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "supernova_inbound_media_ffi", "read")
fn read(path: String) -> Result(BitArray, Nil)

@external(erlang, "supernova_inbound_media_ffi", "delete")
fn delete(path: String) -> Nil

@external(erlang, "supernova_inbound_media_ffi", "sweep")
fn sweep_dir(dir: String, max_age_ms: Int) -> Int

@external(erlang, "supernova_inbound_media_ffi", "random_id")
fn random_id() -> String

@external(erlang, "supernova_inbound_media_ffi", "download")
fn download(url: String, path: String) -> Result(Nil, String)

@external(erlang, "supernova_inbound_media_ffi", "file_size")
fn file_size(path: String) -> Int

@external(erlang, "supernova_inbound_media_ffi", "read_head")
fn read_head(path: String) -> Result(BitArray, Nil)

fn dir(data_dir: String) -> String {
  data_dir <> "/inbound_media"
}

fn path(data_dir: String, id: String) -> String {
  dir(data_dir) <> "/" <> id
}

/// The large kinds of media (PRD-A).
pub type Kind {
  Image
  Audio
  Video
  Document
}

/// What the channel says about a medium.
pub type Declared {
  Declared(
    kind: Kind,
    mime: Option(String),
    seconds: Option(Int),
    file_name: Option(String),
    voice_note: Bool,
    forwarded: Bool,
  )
}

/// A medium kept for a turn: the file is `file_path(data_dir, id)`.
pub type Media {
  Media(
    id: String,
    kind: Kind,
    mime: String,
    size: Int,
    seconds: Option(Int),
    file_name: Option(String),
    voice_note: Bool,
    forwarded: Bool,
  )
}

/// Largest file of a kind: images go inline to the model (20 MB); audio,
/// video and documents may go through the Gemini Files API (2 GB).
pub fn max_bytes_for(kind: Kind) -> Int {
  case kind {
    Image -> 20_000_000
    _ -> 2_000_000_000
  }
}

pub fn file_path(data_dir: String, id: String) -> String {
  path(data_dir, id)
}

fn meta_path(data_dir: String, id: String) -> String {
  path(data_dir, id) <> ".json"
}

/// Keep a medium given whole.
pub fn keep(
  data_dir: String,
  bytes: BitArray,
  declared: Declared,
) -> Result(Media, String) {
  let id = random_id()
  use _ <- result.try(write(path(data_dir, id), bytes))
  finish(data_dir, id, declared)
}

/// Download a medium straight to disk (videos can be large) and keep it.
pub fn fetch(
  data_dir: String,
  url: String,
  declared: Declared,
) -> Result(Media, String) {
  let id = random_id()
  use _ <- result.try(download(url, path(data_dir, id)))
  finish(data_dir, id, declared)
}

fn finish(
  data_dir: String,
  id: String,
  declared: Declared,
) -> Result(Media, String) {
  let file = path(data_dir, id)
  let size = file_size(file)
  let kept = case size > max_bytes_for(declared.kind), read_head(file) {
    True, _ -> Error("larger than the limit for this kind")
    False, Error(Nil) -> Error("could not read the file")
    False, Ok(head) ->
      case sniff(head, declared) {
        Error(reason) -> Error(reason)
        Ok(mime) -> {
          let media =
            Media(
              id: id,
              kind: declared.kind,
              mime: mime,
              size: size,
              seconds: declared.seconds,
              file_name: declared.file_name,
              voice_note: declared.voice_note,
              forwarded: declared.forwarded,
            )
          write(meta_path(data_dir, id), bit_array.from_string(encode(media)))
          |> result.map(fn(_) { media })
        }
      }
  }
  case kept {
    Ok(media) -> Ok(media)
    Error(reason) -> {
      discard(data_dir, id)
      Error(reason)
    }
  }
}

const office = [
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  "application/vnd.oasis.opendocument.text",
  "application/vnd.oasis.opendocument.spreadsheet",
  "application/vnd.oasis.opendocument.presentation",
]

/// The MIME type of these first bytes, when they are what the channel
/// declared.
fn sniff(head: BitArray, declared: Declared) -> Result(String, String) {
  let declared_mime =
    declared.mime
    |> option.map(fn(mime) {
      case string.split_once(mime, ";") {
        Ok(#(base, _)) -> string.trim(base)
        Error(Nil) -> string.trim(mime)
      }
    })
  let family = case head {
    <<"OggS":utf8, _:bits>> -> Ok(#("ogg", [Audio]))
    <<"ID3":utf8, _:bits>>
    | <<0xFF, 0xFB, _:bits>>
    | <<0xFF, 0xF3, _:bits>>
    | <<0xFF, 0xF2, _:bits>> -> Ok(#("mpeg", [Audio]))
    <<"RIFF":utf8, _:bytes-size(4), "WAVE":utf8, _:bits>> ->
      Ok(#("wav", [Audio]))
    <<"RIFF":utf8, _:bytes-size(4), "AVI ":utf8, _:bits>> ->
      Ok(#("avi", [Video]))
    <<"fLaC":utf8, _:bits>> -> Ok(#("flac", [Audio]))
    <<_:bytes-size(4), "ftyp":utf8, brand:bytes-size(4), _:bits>> ->
      case brand {
        <<"qt  ":utf8>> -> Ok(#("quicktime", [Video]))
        <<"3gp":utf8, _:bits>> -> Ok(#("3gpp", [Video, Audio]))
        _ -> Ok(#("mp4", [Video, Audio]))
      }
    <<0x1A, 0x45, 0xDF, 0xA3, _:bits>> -> Ok(#("webm", [Video, Audio]))
    <<"%PDF":utf8, _:bits>> -> Ok(#("pdf", [Document]))
    <<0x50, 0x4B, 0x03, 0x04, _:bits>> -> Ok(#("zip", [Document]))
    _ ->
      case image_type(head) {
        Ok(mime) -> Ok(#(mime, [Image]))
        Error(Nil) ->
          case is_text(head) {
            True -> Ok(#("text", [Document]))
            False -> Error(Nil)
          }
      }
  }
  case family {
    Error(Nil) -> Error("not a type we open")
    Ok(#(name, allowed)) ->
      case list.contains(allowed, declared.kind) {
        False -> Error("the bytes are not what the channel declared")
        True ->
          case name, declared.kind {
            "ogg", _ -> Ok("audio/ogg")
            "mpeg", _ -> Ok("audio/mpeg")
            "wav", _ -> Ok("audio/wav")
            "flac", _ -> Ok("audio/flac")
            "avi", _ -> Ok("video/x-msvideo")
            "quicktime", _ -> Ok("video/quicktime")
            "3gpp", Audio -> Ok("audio/3gpp")
            "3gpp", _ -> Ok("video/3gpp")
            "mp4", Audio -> Ok("audio/mp4")
            "mp4", _ -> Ok("video/mp4")
            "webm", Audio -> Ok("audio/webm")
            "webm", _ -> Ok("video/webm")
            "pdf", _ -> Ok("application/pdf")
            "zip", _ ->
              case declared_mime {
                Some(mime) ->
                  case list.contains(office, mime) {
                    True -> Ok(mime)
                    False -> Error("an archive that is not an Office document")
                  }
                None -> Error("an archive that is not an Office document")
              }
            "text", _ ->
              case declared_mime {
                Some("text/" <> _ as mime) -> Ok(mime)
                _ -> Ok("text/plain")
              }
            image, _ -> Ok(image)
          }
      }
  }
}

/// UTF-8 without NUL bytes in the first bytes.
fn is_text(head: BitArray) -> Bool {
  case bit_array.to_string(head) {
    Ok(text) -> !string.contains(text, "\u{0000}") && text != ""
    // The head may cut a multi-byte character at its end.
    Error(Nil) ->
      case bit_array.slice(head, 0, bit_array.byte_size(head) - 3) {
        Ok(shorter) ->
          case bit_array.to_string(shorter) {
            Ok(text) -> !string.contains(text, "\u{0000}") && text != ""
            Error(Nil) -> False
          }
        Error(Nil) -> False
      }
  }
}

/// The metadata of a kept medium.
pub fn load(data_dir: String, id: String) -> Result(Media, Nil) {
  case is_id(id) {
    False -> Error(Nil)
    True -> {
      use bytes <- result.try(read(meta_path(data_dir, id)))
      use text <- result.try(bit_array.to_string(bytes))
      json.parse(text, decoder(id)) |> result.replace_error(Nil)
    }
  }
}

/// Delete a kept medium and its metadata.
pub fn discard(data_dir: String, id: String) -> Nil {
  delete(path(data_dir, id))
  delete(meta_path(data_dir, id))
}

fn kind_name(kind: Kind) -> String {
  case kind {
    Image -> "image"
    Audio -> "audio"
    Video -> "video"
    Document -> "document"
  }
}

fn encode(media: Media) -> String {
  json.object([
    #("kind", json.string(kind_name(media.kind))),
    #("mime", json.string(media.mime)),
    #("size", json.int(media.size)),
    #("seconds", json.nullable(media.seconds, json.int)),
    #("file_name", json.nullable(media.file_name, json.string)),
    #("voice_note", json.bool(media.voice_note)),
    #("forwarded", json.bool(media.forwarded)),
  ])
  |> json.to_string
}

fn decoder(id: String) -> decode.Decoder(Media) {
  use kind <- decode.field(
    "kind",
    decode.string
      |> decode.then(fn(name) {
        case list.find(kinds, fn(kind) { kind_name(kind) == name }) {
          Ok(kind) -> decode.success(kind)
          Error(Nil) -> decode.failure(Image, "kind")
        }
      }),
  )
  use mime <- decode.field("mime", decode.string)
  use size <- decode.field("size", decode.int)
  use seconds <- decode.field("seconds", decode.optional(decode.int))
  use file_name <- decode.field("file_name", decode.optional(decode.string))
  use voice_note <- decode.field("voice_note", decode.bool)
  use forwarded <- decode.field("forwarded", decode.bool)
  decode.success(Media(
    id:,
    kind:,
    mime:,
    size:,
    seconds:,
    file_name:,
    voice_note:,
    forwarded:,
  ))
}

/// The image type of these bytes, if it is one we accept.
pub fn image_type(bytes: BitArray) -> Result(String, Nil) {
  case bytes {
    <<0xFF, 0xD8, 0xFF, _:bits>> -> Ok("image/jpeg")
    <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _:bits>> ->
      Ok("image/png")
    <<"GIF8":utf8, _:bits>> -> Ok("image/gif")
    <<"RIFF":utf8, _:bytes-size(4), "WEBP":utf8, _:bits>> -> Ok("image/webp")
    _ -> Error(Nil)
  }
}

/// Keep an image; its id goes into the message with `tag`.
pub fn store(data_dir: String, bytes: BitArray) -> Result(String, String) {
  case bit_array.byte_size(bytes) > max_bytes, image_type(bytes) {
    True, _ -> Error("image larger than 5 MB")
    False, Error(Nil) -> Error("not an image we accept")
    False, Ok(_) -> {
      let id = random_id()
      write(path(data_dir, id), bytes) |> result.map(fn(_) { id })
    }
  }
}

pub fn tag(id: String) -> String {
  "\n" <> open <> id <> "]"
}

/// The tag of a kept medium of any kind.
pub fn tag_for(media: Media) -> String {
  "\n[" <> label(media.kind) <> ":" <> media.id <> "]"
}

fn label(kind: Kind) -> String {
  case kind {
    Image -> "imagem"
    Audio -> "áudio"
    Video -> "vídeo"
    Document -> "documento"
  }
}

const kinds = [Image, Audio, Video, Document]

/// The text with every media tag replaced by its placeholder (`[imagem]`,
/// `[áudio]`…), and the media referred to, in order.
pub fn parse(content: String) -> #(String, List(#(Kind, String))) {
  case string.split_once(content, "\n[") {
    Error(Nil) -> #(content, [])
    Ok(#(before, after)) -> {
      let found =
        list.find_map(kinds, fn(kind) {
          let prefix = label(kind) <> ":"
          case string.starts_with(after, prefix) {
            False -> Error(Nil)
            True ->
              case
                string.split_once(
                  string.drop_start(after, string.length(prefix)),
                  "]",
                )
              {
                Ok(#(id, rest)) ->
                  case is_id(id) {
                    True -> Ok(#(kind, id, rest))
                    False -> Error(Nil)
                  }
                Error(Nil) -> Error(Nil)
              }
          }
        })
      case found {
        Ok(#(kind, id, rest)) -> {
          let #(text, refs) = parse(rest)
          #(before <> "\n[" <> label(kind) <> "]" <> text, [#(kind, id), ..refs])
        }
        Error(Nil) -> {
          let #(text, refs) = parse(after)
          #(before <> "\n[" <> text, refs)
        }
      }
    }
  }
}

/// The media a message refers to.
pub fn refs(content: String) -> List(#(Kind, String)) {
  parse(content).1
}

/// The text with each tag replaced by its placeholder, and the images
/// (the turn shows images to the model; other kinds are read before it).
pub fn split(content: String) -> #(String, List(String)) {
  let #(text, refs) = parse(content)
  #(
    text,
    list.filter_map(refs, fn(ref) {
      case ref {
        #(Image, id) -> Ok(id)
        _ -> Error(Nil)
      }
    }),
  )
}

fn is_id(id: String) -> Bool {
  string.length(id) == 32
  && list.all(string.to_graphemes(id), fn(c) {
    string.contains("0123456789abcdef", c)
  })
}

/// What the history and the journal keep of a message.
pub fn for_history(content: String) -> String {
  parse(content).0
}

/// The image as a data URL for the model; the file is deleted.
pub fn take_data_url(data_dir: String, id: String) -> Result(String, Nil) {
  case is_id(id) {
    False -> Error(Nil)
    True -> {
      let file = path(data_dir, id)
      use bytes <- result.try(read(file))
      delete(file)
      use kind <- result.try(image_type(bytes))
      Ok("data:" <> kind <> ";base64," <> bit_array.base64_encode(bytes, True))
    }
  }
}

/// Delete files older than `max_age_ms`; returns how many.
pub fn sweep(data_dir: String, max_age_ms: Int) -> Int {
  sweep_dir(dir(data_dir), max_age_ms)
}
