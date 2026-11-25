//// What a person asked their agent about how to answer (PRD-A):
//// `/transcricao` (their own audios come back transcribed too), `/voz`
//// (answers as voice notes) and how much detail a description carries
//// (`/curto`, `/longo`, `/cego`). Kept in the person's agent folder;
//// `/esquecer` deletes them.

import gleam/dynamic/decode
import gleam/json
import gleam/result
import supernova/core/agent_identity

pub type Preferences {
  Preferences(transcription: Bool, voice: Bool, detail: Detail)
}

/// How much a description of an image, a video or a document carries.
pub type Detail {
  Short
  Normal
  Long
}

pub const none = Preferences(transcription: False, voice: False, detail: Normal)

fn detail_name(detail: Detail) -> String {
  case detail {
    Short -> "curto"
    Normal -> "normal"
    Long -> "longo"
  }
}

pub fn path(data_dir: String, principal: String) -> String {
  agent_identity.agent_dir(data_dir, principal) <> "/preferences.json"
}

pub fn load(data_dir: String, principal: String) -> Preferences {
  read(path(data_dir, principal))
  |> result.try(fn(text) {
    json.parse(text, decoder()) |> result.replace_error(Nil)
  })
  |> result.unwrap(none)
}

pub fn save(
  data_dir: String,
  principal: String,
  preferences: Preferences,
) -> Result(Nil, String) {
  let dir = agent_identity.agent_dir(data_dir, principal)
  use _ <- result.try(ensure_dir(dir))
  let file = path(data_dir, principal)
  use _ <- result.try(write(
    file <> ".tmp",
    json.object([
      #("transcription", json.bool(preferences.transcription)),
      #("voice", json.bool(preferences.voice)),
      #("detail", json.string(detail_name(preferences.detail))),
    ])
      |> json.to_string,
  ))
  rename(file <> ".tmp", file)
}

fn decoder() -> decode.Decoder(Preferences) {
  use transcription <- decode.optional_field(
    "transcription",
    False,
    decode.bool,
  )
  use voice <- decode.optional_field("voice", False, decode.bool)
  use detail <- decode.optional_field(
    "detail",
    Normal,
    decode.string
      |> decode.map(fn(name) {
        case name {
          "curto" -> Short
          "longo" -> Long
          _ -> Normal
        }
      }),
  )
  decode.success(Preferences(transcription, voice, detail))
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_raw(path: String) -> Result(String, String)

fn read(path: String) -> Result(String, Nil) {
  read_raw(path) |> result.replace_error(Nil)
}

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_access_ffi", "rename")
fn rename(from: String, to: String) -> Result(Nil, String)
