//// PRD-A, A-03: the Gemini reader against a fake that serves what the real
//// API answered (test/fixtures/gemini, anonymized).

import gemini_fake
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit/should
import supernova/llm/gemini_media
import test_workspace

fn drain(subject, acc) {
  case process.receive(subject, 0) {
    Ok(x) -> drain(subject, [x, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

pub fn a_small_medium_goes_inline_in_one_call_test() {
  let requests = process.new_subject()
  let base = gemini_fake.start(requests)
  let dir = test_workspace.create_temp_dir("gemini-inline")
  let file = dir <> "/voz.wav"
  let assert Ok(_) = write(file, <<"RIFF":utf8, 0, 0, 0, 0, "WAVE":utf8>>)
  let assert Ok(reply) =
    gemini_media.read(
      gemini_media.Client(api_key: "chave", base: base),
      "gemini-3.5-flash-lite",
      "Transcreva este áudio.",
      file,
      "audio/wav; rate=24000",
      12,
    )
  string.starts_with(
    reply.text,
    "Transcrição do áudio\nOlá, este é um áudio de teste da Supernova.",
  )
  |> should.be_true()
  string.ends_with(reply.text, "Fim da transcrição") |> should.be_true()
  reply.usage |> should.equal(gemini_media.Usage(513, 73))
  let assert [call] = drain(requests, [])
  call.path
  |> should.equal("/v1beta/models/gemini-3.5-flash-lite:generateContent")
  call.key |> should.equal("chave")
  let sent = gemini_fake.text(call.body)
  string.contains(sent, "\"system_instruction\"") |> should.be_true()
  string.contains(sent, "\"mime_type\":\"audio/wav\"") |> should.be_true()
  test_workspace.remove_dir_recursive(dir)
}

pub fn a_large_medium_goes_up_in_parts_and_is_deleted_test() {
  let requests = process.new_subject()
  let base = gemini_fake.start(requests)
  let dir = test_workspace.create_temp_dir("gemini-files")
  let file = dir <> "/video.mp4"
  // A little over 20 MB: two full parts of the announced size, and the rest.
  let size = 20_000_001
  let assert Ok(_) = write(file, <<0:size(160_000_008)>>)
  let assert Ok(reply) =
    gemini_media.read(
      gemini_media.Client(api_key: "chave", base: base),
      "gemini-3.5-flash-lite",
      "Transcreva.",
      file,
      "video/mp4",
      size,
    )
  string.starts_with(reply.text, "Transcrição do áudio") |> should.be_true()
  let part = gemini_fake.granularity()
  let calls = drain(requests, [])
  list.map(calls, fn(call) {
    #(call.method, call.path, call.command, call.offset)
  })
  |> should.equal([
    #("POST", "/upload/v1beta/files", "start", ""),
    #("POST", "/upload/v1beta/files", "upload", "0"),
    #("POST", "/upload/v1beta/files", "upload", string.inspect(part)),
    #(
      "POST",
      "/upload/v1beta/files",
      "upload, finalize",
      string.inspect(2 * part),
    ),
    #("GET", "/v1beta/files/fixture", "", ""),
    #("POST", "/v1beta/models/gemini-3.5-flash-lite:generateContent", "", ""),
    #("DELETE", "/v1beta/files/fixture", "", ""),
  ])
  // The parts have the size the API announced; the last carries the rest.
  let assert [_, first, second, last, ..] = calls
  #(first.size, second.size, last.size)
  |> should.equal(#(part, part, size - 2 * part))
  list.all(calls, fn(call) { call.key == "chave" }) |> should.be_true()
  test_workspace.remove_dir_recursive(dir)
}

pub fn the_api_error_message_is_kept_test() {
  let requests = process.new_subject()
  let base = gemini_fake.start(requests)
  let dir = test_workspace.create_temp_dir("gemini-error")
  let file = dir <> "/x.ogg"
  let assert Ok(_) = write(file, <<"x":utf8>>)
  gemini_media.read(
    gemini_media.Client(api_key: "chave", base: base),
    "gemini-3.5-flash-lite",
    "Leia.",
    file,
    "audio/nao-existe",
    1,
  )
  |> should.equal(Error(
    "Gemini answered 400: Unable to process input: the file or media data is empty, corrupted, or malformed.",
  ))
  test_workspace.remove_dir_recursive(dir)
}

pub fn an_unreachable_api_is_an_error_test() {
  let requests = process.new_subject()
  let _ = gemini_fake.start(requests)
  let dir = test_workspace.create_temp_dir("gemini-origin")
  let file = dir <> "/v.mp4"
  let assert Ok(_) = write(file, <<0:size(160_000_008)>>)
  gemini_media.read(
    gemini_media.Client(api_key: "chave", base: "http://127.0.0.1:1"),
    "m",
    "x",
    file,
    "video/mp4",
    20_000_001,
  )
  |> should.be_error
  test_workspace.remove_dir_recursive(dir)
}

pub fn replies_without_text_are_errors_test() {
  gemini_media.parse_reply(
    "{\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"pensando\"}]}}]}",
  )
  |> should.equal(Error("Gemini answered without text"))
  gemini_media.parse_reply("{\"candidates\":[]}")
  |> should.equal(Error("Gemini answered without text"))
  gemini_media.parse_reply("não é json")
  |> should.equal(Error("Gemini answered in an unexpected format"))
}

@external(erlang, "supernova_inbound_media_ffi", "write")
fn write(path: String, bytes: BitArray) -> Result(Nil, String)

/// PRD-A, A-10: frames go in one call, in order (recorded: the real API
/// told the animation's counter going 0, 1, 2 from eight frames).
pub fn frames_are_read_in_one_call_test() {
  let requests = process.new_subject()
  let base = gemini_fake.start(requests)
  let dir = test_workspace.create_temp_dir("gemini-frames")
  let assert Ok(_) = write(dir <> "/q0.png", <<1, 2, 3>>)
  let assert Ok(_) = write(dir <> "/q1.png", <<4, 5, 6>>)
  let assert Ok(reply) =
    gemini_media.read_frames(
      gemini_media.Client(api_key: "chave", base: base),
      "gemini-3.5-flash-lite",
      "Faça a audiodescrição deste sticker animado.",
      [dir <> "/q0.png", dir <> "/q1.png"],
    )
  string.starts_with(reply.text, "Audiodescrição do sticker")
  |> should.be_true()
  string.contains(reply.text, "depois muda para 1") |> should.be_true()
  let assert [call] = drain(requests, [])
  let sent = gemini_fake.text(call.body)
  string.split(sent, "\"image/png\"") |> list.length |> should.equal(3)
  test_workspace.remove_dir_recursive(dir)
}
