//// PRD-A, A-02: the media capability for every kind. The kind comes from
//// the bytes, checked against what the channel declared; each file keeps
//// its metadata beside it.

import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should
import gowa_fake
import supernova/channel/inbound_media.{Audio, Document, Image, Video}
import test_workspace

const ogg = <<"OggS":utf8, 0, 2, 0, 0, 0, 0, 0, 0>>

const mp4 = <<0, 0, 0, 24, "ftypisom":utf8, 0, 0, 2, 0>>

const pdf = <<"%PDF-1.7\n":utf8, 1, 2, 3>>

const zip = <<0x50, 0x4B, 0x03, 0x04, 20, 0>>

fn declared(kind, mime) {
  inbound_media.Declared(
    kind: kind,
    mime: mime,
    seconds: Some(42),
    file_name: None,
    voice_note: False,
    forwarded: False,
  )
}

pub fn each_kind_is_kept_with_its_metadata_test() {
  let dir = test_workspace.create_temp_dir("media-kinds")
  let assert Ok(audio) =
    inbound_media.keep(
      dir,
      ogg,
      declared(Audio, Some("audio/ogg; codecs=opus")),
    )
  audio.kind |> should.equal(Audio)
  audio.mime |> should.equal("audio/ogg")
  let assert Ok(loaded) = inbound_media.load(dir, audio.id)
  loaded |> should.equal(audio)
  loaded.seconds |> should.equal(Some(42))

  let assert Ok(video) = inbound_media.keep(dir, mp4, declared(Video, None))
  video.mime |> should.equal("video/mp4")
  // The same container, declared as audio (an M4A voice memo).
  let assert Ok(m4a) = inbound_media.keep(dir, mp4, declared(Audio, None))
  m4a.mime |> should.equal("audio/mp4")

  let assert Ok(document) =
    inbound_media.keep(dir, pdf, declared(Document, None))
  document.mime |> should.equal("application/pdf")
  let docx =
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  let assert Ok(office) =
    inbound_media.keep(dir, zip, declared(Document, Some(docx)))
  office.mime |> should.equal(docx)
  let assert Ok(text) =
    inbound_media.keep(
      dir,
      <<"linha um\nlinha dois":utf8>>,
      declared(Document, None),
    )
  text.mime |> should.equal("text/plain")
  test_workspace.remove_dir_recursive(dir)
}

pub fn bytes_that_are_not_what_was_declared_are_refused_test() {
  let dir = test_workspace.create_temp_dir("media-mismatch")
  inbound_media.keep(dir, pdf, declared(Audio, None)) |> should.be_error
  inbound_media.keep(dir, ogg, declared(Image, None)) |> should.be_error
  // A zip that is not an Office document is not opened.
  inbound_media.keep(dir, zip, declared(Document, Some("application/zip")))
  |> should.be_error
  inbound_media.keep(dir, <<0, 1, 2, 0, 255>>, declared(Document, None))
  |> should.be_error
  test_workspace.remove_dir_recursive(dir)
}

pub fn tags_carry_the_kind_and_history_keeps_placeholders_test() {
  let dir = test_workspace.create_temp_dir("media-tags")
  let assert Ok(audio) = inbound_media.keep(dir, ogg, declared(Audio, None))
  let assert Ok(document) =
    inbound_media.keep(dir, pdf, declared(Document, None))
  let content =
    "ouve e lê"
    <> inbound_media.tag_for(audio)
    <> inbound_media.tag_for(document)
  inbound_media.refs(content)
  |> should.equal([#(Audio, audio.id), #(Document, document.id)])
  inbound_media.for_history(content)
  |> should.equal("ouve e lê\n[áudio]\n[documento]")
  inbound_media.discard(dir, audio.id)
  inbound_media.load(dir, audio.id) |> should.be_error
  test_workspace.remove_dir_recursive(dir)
}

/// A medium is downloaded straight to disk, then checked like any other.
pub fn a_medium_is_fetched_to_disk_test() {
  let dir = test_workspace.create_temp_dir("media-fetch")
  let bridge = gowa_fake.start(process.new_subject())
  let assert Ok(media) =
    inbound_media.fetch(
      dir,
      bridge <> "/statics/media/foto.png",
      declared(Image, None),
    )
  media.mime |> should.equal("image/png")
  media.size |> should.equal(11)
  inbound_media.fetch(
    dir,
    bridge <> "/statics/media/foto.png",
    declared(Audio, None),
  )
  |> should.be_error
  inbound_media.fetch(dir, "http://127.0.0.1:1/nada", declared(Image, None))
  |> should.be_error
  test_workspace.remove_dir_recursive(dir)
}
