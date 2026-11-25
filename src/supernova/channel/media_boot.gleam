//// Wiring the media reader at boot (PRD-A, A-04): Gemini reads, the
//// ledger admits and charges. Without the key, or without a ledger, there
//// is no paid reading (media become notes).

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import supernova/channel/media_reading
import supernova/channel/voice
import supernova/config
import supernova/core/closed_group/global as closed_group_global
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/llm/gemini_media

/// gemini-3.5-flash-lite, paid tier, as listed on 24/11/2026: US$ 0.30 per
/// million input tokens (text, image, video and audio alike) and US$ 2.50
/// per million output tokens.
pub const input_usd_per_million = 0.3

pub const output_usd_per_million = 2.5

pub fn settings(
  cfg: config.Config,
  base: String,
) -> Option(media_reading.Settings) {
  case cfg.media.api_key {
    None -> None
    Some(key) -> {
      let client = gemini_media.Client(api_key: key, base: base)
      let model = cfg.media.reader_model
      Some(media_reading.Settings(
        data_dir: cfg.data_dir,
        reader: fn(path, mime, size, instruction) {
          gemini_media.read(client, model, instruction, path, mime, size)
          |> result.map(fn(reply) {
            media_reading.Read(
              reply.text,
              reply.usage.input_tokens,
              reply.usage.output_tokens,
            )
          })
        },
        admit: fn(principal, estimate_tokens) {
          case closed_group_global.get_ledger() {
            // Fail closed: without a ledger to admit the call, no paid call.
            None -> Error(Nil)
            Some(ledger) ->
              admit(
                ledger,
                model,
                principal,
                cfg.instance_budget.daily_usd,
                estimate_tokens,
              )
          }
        },
        frames: fn(path) { sticker_frames(path, path <> ".frames", 8) },
        frames_reader: fn(paths, instruction) {
          gemini_media.read_frames(client, model, instruction, paths)
          |> result.map(fn(reply) {
            media_reading.Read(
              reply.text,
              reply.usage.input_tokens,
              reply.usage.output_tokens,
            )
          })
        },
        audio: cfg.media.audio,
        video: cfg.media.video,
        document: cfg.media.document,
      ))
    }
  }
}

fn cost(input: Int, output: Int) -> Float {
  int.to_float(input)
  *. input_usd_per_million
  /. 1_000_000.0
  +. int.to_float(output)
  *. output_usd_per_million
  /. 1_000_000.0
}

/// Admit a reading against the day's cap; the result records what it cost,
/// or releases the reservation when nothing was spent.
pub fn admit(
  ledger: ledger_actor.ResourceLedger,
  model: String,
  principal: String,
  cap_usd: Float,
  estimate_tokens: Int,
) -> Result(fn(Int, Int) -> Nil, Nil) {
  let call_id = "media:" <> int.to_string(unique_integer())
  case
    ledger_actor.admit_llm_call(
      ledger,
      call_id,
      cap_usd,
      cost(estimate_tokens, 0),
    )
  {
    Error(_) -> Error(Nil)
    Ok(Nil) ->
      Ok(fn(input, output) {
        case input + output > 0 {
          False -> ledger_actor.release_reservation(ledger, call_id)
          True -> {
            let _ =
              ledger_actor.try_record_llm_usage_with_call_id(
                ledger,
                principal,
                "gemini",
                model,
                input,
                output,
                cost(input, output),
                call_id,
              )
            Nil
          }
        }
      })
  }
}

/// Publish the reader and the voice, or turn both off. True when on.
pub fn publish(cfg: config.Config) -> Bool {
  case settings(cfg, gemini_media.google) {
    Some(settings) -> {
      media_reading.configure(settings)
      let assert Some(speaking) =
        voice_settings(cfg, gemini_media.google, now_ms)
      voice.configure(speaking)
      True
    }
    None -> {
      media_reading.clear()
      voice.clear()
      False
    }
  }
}

/// gemini-3.8-flash-lite-tts, paid tier, as listed on 24/11/2026: US$ 0.50
/// per million input tokens and US$ 6.00 per million audio tokens through
/// 31/12/2026; US$ 1.00 and US$ 12.00 from 1/1/2027.
pub fn speech_usd_per_million(now_ms: Int) -> #(Float, Float) {
  case now_ms < 1_798_761_600_000 {
    True -> #(0.5, 6.0)
    False -> #(1.0, 12.0)
  }
}

/// The voice of `/voz` (PRD-A, A-06): the same key, the TTS model and voice
/// of `media`, admitted and charged like the readings.
pub fn voice_settings(
  cfg: config.Config,
  base: String,
  now: fn() -> Int,
) -> Option(voice.Settings) {
  case cfg.media.api_key {
    None -> None
    Some(key) -> {
      let client = gemini_media.Client(api_key: key, base: base)
      let model = cfg.media.speech_model
      let price = fn() { speech_usd_per_million(now()) }
      let cost = fn(input: Int, output: Int) {
        let #(in_rate, out_rate) = price()
        int.to_float(input)
        *. in_rate
        /. 1_000_000.0
        +. int.to_float(output)
        *. out_rate
        /. 1_000_000.0
      }
      Some(
        voice.Settings(
          data_dir: cfg.data_dir,
          speak: fn(text) {
            gemini_media.speak(client, model, cfg.media.voice, text)
            |> result.map(fn(spoken) {
              let #(wav, usage) = spoken
              #(wav, usage.input_tokens, usage.output_tokens)
            })
          },
          admit: fn(principal, input, output) {
            case closed_group_global.get_ledger() {
              None -> Error(Nil)
              Some(ledger) -> {
                let call_id = "voice:" <> int.to_string(unique_integer())
                case
                  ledger_actor.admit_llm_call(
                    ledger,
                    call_id,
                    cfg.instance_budget.daily_usd,
                    cost(input, output),
                  )
                {
                  Error(_) -> Error(Nil)
                  Ok(Nil) ->
                    Ok(fn(input, output) {
                      case input + output > 0 {
                        False ->
                          ledger_actor.release_reservation(ledger, call_id)
                        True -> {
                          let _ =
                            ledger_actor.try_record_llm_usage_with_call_id(
                              ledger,
                              principal,
                              "gemini",
                              model,
                              input,
                              output,
                              cost(input, output),
                              call_id,
                            )
                          Nil
                        }
                      }
                    })
                }
              }
            }
          },
        ),
      )
    }
  }
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

/// Split an animated sticker into up to `max` composed frames (PNG), with
/// `priv/media/sticker_frames.py` (Pillow). The frames' directory is
/// deleted with the sticker's file.
@external(erlang, "supernova_sticker_ffi", "frames")
pub fn sticker_frames(
  path: String,
  out_dir: String,
  max: Int,
) -> Result(List(String), String)

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
