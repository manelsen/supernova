//// PRD-C, C-05: media a person sends. An image is kept in a temporary file
//// named in the message as `[imagem:<id>]`; the model sees it once, then
//// the file is gone and the history keeps `[imagem]`.

import gleam/bit_array
import gleam/string
import gleeunit/should
import supernova/channel/inbound_media
import test_workspace

const png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3>>

const jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 9, 9>>

pub fn an_image_is_kept_then_taken_once_test() {
  let dir = test_workspace.create_temp_dir("media")
  let assert Ok(id) = inbound_media.store(dir, png)
  let content = "olha isso" <> inbound_media.tag(id)
  inbound_media.split(content) |> should.equal(#("olha isso\n[imagem]", [id]))
  let assert Ok(url) = inbound_media.take_data_url(dir, id)
  url
  |> should.equal(
    "data:image/png;base64," <> bit_array.base64_encode(png, True),
  )
  inbound_media.take_data_url(dir, id) |> should.be_error
  test_workspace.remove_dir_recursive(dir)
}

pub fn only_images_within_the_limit_are_kept_test() {
  let dir = test_workspace.create_temp_dir("media-policy")
  let assert Ok(id) = inbound_media.store(dir, jpeg)
  let assert Ok(url) = inbound_media.take_data_url(dir, id)
  string.starts_with(url, "data:image/jpeg;base64,") |> should.be_true()
  inbound_media.store(dir, <<"<html>":utf8>>) |> should.be_error
  inbound_media.store(dir, <<"%PDF-1.4":utf8>>) |> should.be_error
  let big = <<png:bits, 0:size(41_943_048)>>
  inbound_media.store(dir, big) |> should.be_error
  test_workspace.remove_dir_recursive(dir)
}

pub fn the_history_keeps_only_a_placeholder_test() {
  inbound_media.for_history(
    "a" <> inbound_media.tag("0123456789abcdef0123456789abcdef"),
  )
  |> should.equal("a\n[imagem]")
  // Text that only looks like a tag stays as it is.
  inbound_media.split("[imagem:nao-e-id] oi")
  |> should.equal(#("[imagem:nao-e-id] oi", []))
  inbound_media.for_history("sem imagem") |> should.equal("sem imagem")
}

pub fn leftovers_are_swept_test() {
  let dir = test_workspace.create_temp_dir("media-sweep")
  let assert Ok(old) = inbound_media.store(dir, png)
  inbound_media.sweep(dir, 0) |> should.equal(1)
  inbound_media.take_data_url(dir, old) |> should.be_error
  test_workspace.remove_dir_recursive(dir)
}
