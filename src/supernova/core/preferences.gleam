//// What a person asked their agent about how to answer (PRD-A, D6):
//// `/transcricao` (their own audios come back transcribed too) and
//// `/voz` (answers as voice notes). Kept in the person's agent folder;
//// `/esquecer` deletes them.

import gleam/dynamic/decode
import gleam/json
import gleam/result
import supernova/core/agent_identity

pub type Preferences {
  Preferences(transcription: Bool, voice: Bool)
}

pub const none = Preferences(transcription: False, voice: False)

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
  decode.success(Preferences(transcription, voice))
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
