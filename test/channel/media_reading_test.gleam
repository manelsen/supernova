//// PRD-A, A-04: before the turn, each audio, video and document the person
//// sent becomes text (D1, D4): transcription, audio description, the
//// document's content. Charged to the person; a failure is a note, never
//// silence.

import gleam/erlang/process
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
