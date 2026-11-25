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
import gleam/list
import gleam/result
import gleam/string

/// Largest file kept, in bytes.
pub const max_bytes = 5_242_880

/// Files older than this are swept at boot, in milliseconds.
pub const max_age_ms = 86_400_000

const open = "[imagem:"

const placeholder = "\n[imagem]"

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

fn dir(data_dir: String) -> String {
  data_dir <> "/inbound_media"
}

fn path(data_dir: String, id: String) -> String {
  dir(data_dir) <> "/" <> id
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

/// The text with each image tag replaced by `[imagem]`, and the ids found.
pub fn split(content: String) -> #(String, List(String)) {
  case string.split_once(content, "\n" <> open) {
    Error(Nil) -> #(content, [])
    Ok(#(before, after)) ->
      case string.split_once(after, "]") {
        Ok(#(id, rest)) ->
          case is_id(id) {
            True -> {
              let #(text, ids) = split(rest)
              #(before <> placeholder <> text, [id, ..ids])
            }
            False -> {
              let #(text, ids) = split(after)
              #(before <> "\n" <> open <> text, ids)
            }
          }
        Error(Nil) -> #(content, [])
      }
  }
}

fn is_id(id: String) -> Bool {
  string.length(id) == 32
  && list.all(string.to_graphemes(id), fn(c) {
    string.contains("0123456789abcdef", c)
  })
}

/// What the history and the journal keep of a message.
pub fn for_history(content: String) -> String {
  split(content).0
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
