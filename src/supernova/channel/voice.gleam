//// Answers as voice notes (PRD-A, A-06): for a person who asked `/voz`,
//// on a channel that sends voice, the agent's answer is made to be heard
//// (Amélie's voice sanitizer), spoken by the TTS, and sent as a voice
//// note. Admitted in the ledger and charged to the person like any model
//// call. If anything fails, the answer goes as text, as always; the
//// history keeps the text either way.

import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/channel/port
import supernova/channel/voice_text

/// Speaks text: WAV bytes and the input and output tokens it cost.
pub type Speaker =
  fn(String) -> Result(#(BitArray, Int, Int), String)

/// Admits a paid call for a person, estimated in (input, output) tokens;
/// the result settles it with the tokens spent (0, 0 releases it).
pub type Admit =
  fn(String, Int, Int) -> Result(fn(Int, Int) -> Nil, Nil)

pub type Settings {
  Settings(data_dir: String, speak: Speaker, admit: Admit)
}

const key = "supernova_voice"

@external(erlang, "supernova_global_ffi", "global_put")
fn put(key: String, settings: Option(Settings)) -> Nil

@external(erlang, "supernova_tool_limits_ffi", "get")
fn get(key: String) -> Result(Option(Settings), Nil)

pub fn configure(settings: Settings) -> Nil {
  put(key, Some(settings))
}

pub fn clear() -> Nil {
  put(key, None)
}

pub fn current() -> Option(Settings) {
  get(key) |> result.unwrap(None)
}

/// Where voice notes wait to be sent; the WhatsApp adapter sends local
/// files only from here.
pub fn dir(data_dir: String) -> String {
  data_dir <> "/voice"
}

/// Tokens of speech for a text: about 15 characters a second, 25 tokens
/// a second of audio.
pub fn estimate(text: String) -> #(Int, Int) {
  let chars = string.length(text)
  #(chars / 4 + 50, chars / 15 * 25 + 250)
}

/// Send `reply` as a voice note for `principal`; as text when that fails.
pub fn deliver(
  settings: Settings,
  principal: String,
  reply: port.ChannelReply,
  send: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
) -> Result(Nil, port.ChannelError) {
  let text = voice_text.for_speech(reply.content)
  let #(input, output) = estimate(text)
  let spoken = case text, settings.admit(principal, input, output) {
    "", _ -> Error(Nil)
    _, Error(Nil) -> Error(Nil)
    _, Ok(settle) ->
      case settings.speak(text) {
        Error(_) -> {
          settle(0, 0)
          Error(Nil)
        }
        Ok(#(wav, input, output)) -> {
          settle(input, output)
          let file = dir(settings.data_dir) <> "/" <> random_id() <> ".wav"
          case write(file, wav) {
            Error(_) -> Error(Nil)
            Ok(Nil) -> {
              let sent =
                send(
                  port.ChannelReply(..reply, content: "", media: [
                    port.AudioMedia(
                      url: "file://" <> file,
                      mime_type: Some("audio/wav"),
                    ),
                  ]),
                )
              delete(file)
              case sent {
                Ok(Nil) -> Ok(Nil)
                Error(_) -> Error(Nil)
              }
            }
          }
        }
      }
  }
  case spoken {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) -> send(reply)
  }
}

@external(erlang, "supernova_inbound_media_ffi", "write")
fn write(path: String, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "supernova_inbound_media_ffi", "delete")
fn delete(path: String) -> Nil

@external(erlang, "supernova_inbound_media_ffi", "random_id")
fn random_id() -> String
