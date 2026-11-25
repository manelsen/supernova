//// PRD-A, A-04: before the turn, each audio, video and document the person
//// sent becomes text (D1, D4): transcription, audio description, the
//// document's content. Charged to the person; a failure is a note, never
//// silence.

import gemini_fake
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/channel/inbound_media.{Audio, Document, Image, Video}
import supernova/channel/media_boot
import supernova/channel/media_reading
import supernova/config
import supernova/core/media_prompts
import test_workspace

const ogg = <<"OggS":utf8, 0, 2, 0, 0, 0, 0, 0, 0>>

const png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3>>

fn declared(kind, seconds) {
  inbound_media.Declared(
    kind: kind,
    mime: None,
    seconds: seconds,
    file_name: None,
    voice_note: True,
    forwarded: False,
  )
}

fn reader(replies: process.Subject(String)) -> media_reading.Reader {
  fn(_path, mime, _size, instruction) {
    process.send(replies, mime <> "|" <> instruction)
    case string.contains(instruction, "Transcreva este áudio") {
      True ->
        Ok(media_reading.Read(
          media_prompts.audio_start
            <> "\nOi, tudo bem?\n"
            <> media_prompts.audio_end,
          120,
          30,
        ))
      False -> Error("Gemini answered 500")
    }
  }
}

fn settings(dir, reader, admit, modes: #(Bool, Bool, Bool)) {
  media_reading.Settings(
    data_dir: dir,
    reader: reader,
    frames: fn(_) { Error("no frames here") },
    frames_reader: fn(_, _) { Error("no frames here") },
    admit: admit,
    audio: modes.0,
    video: modes.1,
    document: modes.2,
  )
}

fn always_admit(charges: process.Subject(#(String, Int, Int))) {
  fn(principal, _estimate) {
    Ok(fn(input, output) { process.send(charges, #(principal, input, output)) })
  }
}

pub fn an_audio_becomes_its_transcription_and_is_charged_test() {
  let dir = test_workspace.create_temp_dir("reading-audio")
  let seen = process.new_subject()
  let charges = process.new_subject()
  let assert Ok(audio) = inbound_media.keep(dir, ogg, declared(Audio, Some(42)))
  let content = "ouve isso" <> inbound_media.tag_for(audio)
  media_reading.prepare(
    settings(dir, reader(seen), always_admit(charges), #(True, True, True)),
    "telegram:7",
    content,
  )
  |> should.equal(
    "ouve isso\n[mensagem de voz de 0:42, transcrita]\nOi, tudo bem?",
  )
  let assert Ok(call) = process.receive(seen, 100)
  string.starts_with(call, "audio/ogg|Transcreva este áudio")
  |> should.be_true()
  process.receive(charges, 100) |> should.equal(Ok(#("telegram:7", 120, 30)))
  // The file is gone once read.
  inbound_media.load(dir, audio.id) |> should.be_error
  test_workspace.remove_dir_recursive(dir)
}

pub fn a_reading_that_fails_is_a_note_and_charges_nothing_test() {
  let dir = test_workspace.create_temp_dir("reading-fail")
  let seen = process.new_subject()
  let charges = process.new_subject()
  let assert Ok(video) =
    inbound_media.keep(
      dir,
      <<0, 0, 0, 24, "ftypisom":utf8, 0, 0, 2, 0>>,
      declared(Video, Some(70)),
    )
  media_reading.prepare(
    settings(dir, reader(seen), always_admit(charges), #(True, True, True)),
    "telegram:7",
    inbound_media.tag_for(video),
  )
  |> should.equal(
    "\n[um vídeo de 1:10 que não consegui ver: Gemini answered 500]",
  )
  process.receive(charges, 100) |> should.equal(Ok(#("telegram:7", 0, 0)))
  test_workspace.remove_dir_recursive(dir)
}

pub fn a_kind_turned_off_or_a_denied_budget_is_a_note_test() {
  let dir = test_workspace.create_temp_dir("reading-off")
  let seen = process.new_subject()
  let charges = process.new_subject()
  let assert Ok(document) =
    inbound_media.keep(
      dir,
      <<"%PDF-1.7":utf8>>,
      inbound_media.Declared(
        ..declared(Document, None),
        file_name: Some("conta.pdf"),
        voice_note: False,
      ),
    )
  media_reading.prepare(
    settings(dir, reader(seen), always_admit(charges), #(True, True, False)),
    "telegram:7",
    inbound_media.tag_for(document),
  )
  |> should.equal("\n[um documento (conta.pdf), que ainda não consigo ler]")
  process.receive(seen, 50) |> should.equal(Error(Nil))

  let assert Ok(audio) = inbound_media.keep(dir, ogg, declared(Audio, Some(5)))
  media_reading.prepare(
    settings(dir, reader(seen), fn(_, _) { Error(Nil) }, #(True, True, True)),
    "telegram:7",
    inbound_media.tag_for(audio),
  )
  |> should.equal(
    "\n[uma mensagem de voz de 0:05 que não consegui ouvir: o limite de gasto do dia foi atingido]",
  )
  process.receive(seen, 50) |> should.equal(Error(Nil))
  test_workspace.remove_dir_recursive(dir)
}

pub fn images_are_left_to_the_turn_test() {
  let dir = test_workspace.create_temp_dir("reading-image")
  let seen = process.new_subject()
  let charges = process.new_subject()
  let assert Ok(id) = inbound_media.store(dir, png)
  let content = "olha" <> inbound_media.tag(id)
  media_reading.prepare(
    settings(dir, reader(seen), always_admit(charges), #(True, True, True)),
    "telegram:7",
    content,
  )
  |> should.equal(content)
  let _ = Image
  test_workspace.remove_dir_recursive(dir)
}

pub fn the_estimate_follows_the_documented_rates_test() {
  // 25 tokens per second of audio; about 100 per second of video (frames
  // and sound); about 560 per page, guessed from the size, for documents.
  media_reading.estimate_tokens(Audio, Some(60), 1000)
  |> should.equal(1500 + 2000)
  media_reading.estimate_tokens(Video, Some(60), 1000)
  |> should.equal(6000 + 2000)
  media_reading.estimate_tokens(Document, None, 300_000)
  |> should.equal(5600 + 2000)
}

pub fn the_reader_is_published_only_with_a_key_test() {
  let base = config.default_config()
  media_boot.publish(base) |> should.be_false()
  media_reading.current() |> should.equal(None)
  let keyed =
    config.Config(
      ..base,
      media: config.MediaConfig(..base.media, api_key: Some("chave")),
    )
  media_boot.publish(keyed) |> should.be_true()
  let assert Some(settings) = media_reading.current()
  settings.audio |> should.be_true()
  // Without a ledger there is no paid reading.
  settings.admit("telegram:7", 100) |> should.equal(Error(Nil))
  media_reading.clear()
  media_reading.current() |> should.equal(None)
}

pub fn markers_are_stripped_test() {
  media_prompts.strip_markers(
    "  Transcrição do áudio\nOi.\nFim da transcrição  ",
    media_prompts.audio_start,
    media_prompts.audio_end,
  )
  |> should.equal("Oi.")
  media_prompts.strip_markers("Só texto", "A", "B") |> should.equal("Só texto")
  string.contains(media_prompts.video(), "Transcrição da fala")
  |> should.be_true()
  string.contains(media_prompts.document(), "linha digitável")
  |> should.be_true()
}

const webp = <<"RIFF":utf8, 26, 0, 0, 0, "WEBPVP8X":utf8, 10, 0, 0, 0, 2>>

/// PRD-A, A-10: an animated sticker is split into frames and read in
/// order, in one call.
pub fn an_animated_sticker_is_read_frame_by_frame_test() {
  let dir = test_workspace.create_temp_dir("reading-sticker")
  let calls = process.new_subject()
  let assert Ok(sticker) =
    inbound_media.keep(
      dir,
      webp,
      inbound_media.Declared(
        kind: inbound_media.Sticker,
        mime: Some("image/webp"),
        seconds: None,
        file_name: None,
        voice_note: False,
        forwarded: False,
      ),
    )
  let settings =
    media_reading.Settings(
      data_dir: dir,
      reader: fn(_, _, _, _) { Error("not this one") },
      frames: fn(path) {
        process.send(
          calls,
          "frames:" <> string.slice(path, string.length(path) - 32, 32),
        )
        Ok(["q0.png", "q1.png", "q2.png"])
      },
      frames_reader: fn(frames, instruction) {
        process.send(calls, "read:" <> string.join(frames, ","))
        string.contains(instruction, "sticker animado") |> should.be_true()
        Ok(media_reading.Read(
          "Audiodescrição do sticker\nUm gato acena.\nFim da audiodescrição",
          3000,
          40,
        ))
      },
      admit: fn(_, estimate) {
        estimate |> should.equal(8 * 1120 + 2000)
        Ok(fn(_, _) { Nil })
      },
      audio: True,
      video: True,
      document: True,
    )
  media_reading.prepare(settings, "telegram:7", inbound_media.tag_for(sticker))
  |> should.equal("\n[figurinha animada, descrita]\nUm gato acena.")
  process.receive(calls, 100) |> should.equal(Ok("frames:" <> sticker.id))
  process.receive(calls, 100) |> should.equal(Ok("read:q0.png,q1.png,q2.png"))
  test_workspace.remove_dir_recursive(dir)
}

/// The real splitter (Pillow). Where Pillow is missing, it says so.
pub fn the_splitter_composes_frames_or_says_pillow_is_missing_test() {
  let dir = test_workspace.create_temp_dir("splitter")
  case
    media_boot.sticker_frames(
      "test/fixtures/media/animated.webp",
      dir <> "/q",
      4,
    )
  {
    Ok(frames) -> {
      frames |> should.not_equal([])
      { frames |> list.length <= 4 } |> should.be_true()
    }
    Error(reason) ->
      {
        reason == "Pillow is not installed"
        || reason == "python3 is not installed"
      }
      |> should.be_true()
  }
  test_workspace.remove_dir_recursive(dir)
}

/// The boot wires the sticker splitter and the frames reader to Gemini.
pub fn the_boot_wires_frames_to_gemini_test() {
  let base = config.default_config()
  let dir = test_workspace.create_temp_dir("boot-frames")
  let keyed =
    config.Config(
      ..base,
      data_dir: dir,
      media: config.MediaConfig(..base.media, api_key: Some("chave")),
    )
  let gemini = gemini_fake.start(process.new_subject())
  let assert Some(settings) = media_boot.settings(keyed, gemini)
  let assert Ok(_) = write(dir <> "/q0.png", <<1, 2, 3>>)
  let assert Ok(read) =
    settings.frames_reader([dir <> "/q0.png"], "Descreva o sticker animado.")
  string.starts_with(read.text, "Audiodescrição do sticker") |> should.be_true()
  { read.input_tokens > 0 } |> should.be_true()
  // The splitter answers either frames or why it cannot.
  case settings.frames("test/fixtures/media/animated.webp") {
    Ok(frames) -> frames |> should.not_equal([])
    Error(reason) -> { reason != "" } |> should.be_true()
  }
  let assert Ok(audio_read) =
    settings.reader(dir <> "/q0.png", "audio/ogg", 3, "Transcreva este áudio.")
  string.starts_with(audio_read.text, "Transcrição do áudio")
  |> should.be_true()
  test_workspace.remove_dir_recursive(dir)
}

/// PRD-A, A-06: the voice is wired at boot to Gemini's TTS, priced by date
/// (the price doubles on 1/1/2027).
pub fn the_boot_wires_the_voice_test() {
  let base = config.default_config()
  media_boot.voice_settings(base, "http://x", fn() { 0 }) |> should.equal(None)
  let keyed =
    config.Config(
      ..base,
      media: config.MediaConfig(..base.media, api_key: Some("chave")),
    )
  let gemini = gemini_fake.start(process.new_subject())
  let assert Some(speaking) =
    media_boot.voice_settings(keyed, gemini, fn() { 0 })
  let assert Ok(#(wav, 61, 430)) = speaking.speak("Olá!")
  let assert <<"RIFF":utf8, _:bits>> = wav
  // Without a ledger, no paid speech.
  speaking.admit("x", 1, 1) |> should.equal(Error(Nil))
  media_boot.speech_usd_per_million(1_798_761_599_999)
  |> should.equal(#(0.5, 6.0))
  media_boot.speech_usd_per_million(1_798_761_600_000)
  |> should.equal(#(1.0, 12.0))
}

@external(erlang, "supernova_inbound_media_ffi", "write")
fn write(path: String, bytes: BitArray) -> Result(Nil, String)
