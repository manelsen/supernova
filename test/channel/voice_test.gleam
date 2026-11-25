//// PRD-A, A-06: answers as voice notes, and text when speaking fails.

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/channel/port
import supernova/channel/voice
import test_workspace

const wav = <<"RIFF":utf8, 4, 0, 0, 0, "WAVE":utf8>>

fn reply(content: String) -> port.ChannelReply {
  port.ChannelReply(
    channel_id: "5511@s.whatsapp.net",
    content: content,
    reply_to_id: Some("M1"),
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: None,
    media: [],
  )
}

pub fn an_answer_goes_as_a_voice_note_test() {
  let dir = test_workspace.create_temp_dir("voice")
  let spoken = process.new_subject()
  let charged = process.new_subject()
  let sent = process.new_subject()
  let settings =
    voice.Settings(
      data_dir: dir,
      speak: fn(text) {
        process.send(spoken, text)
        Ok(#(wav, 12, 300))
      },
      admit: fn(principal, _, _) {
        Ok(fn(input, output) {
          process.send(charged, #(principal, input, output))
        })
      },
    )
  let assert Ok(Nil) =
    voice.deliver(settings, "whatsapp:5511", reply("**Oi**, tudo bem?"), fn(r) {
      process.send(sent, r)
      Ok(Nil)
    })
  // What is read aloud has no Markdown marks.
  process.receive(spoken, 100) |> should.equal(Ok("Oi, tudo bem?"))
  process.receive(charged, 100) |> should.equal(Ok(#("whatsapp:5511", 12, 300)))
  let assert Ok(note) = process.receive(sent, 100)
  note.content |> should.equal("")
  note.reply_to_id |> should.equal(Some("M1"))
  let assert [port.AudioMedia(url, Some("audio/wav"))] = note.media
  string.starts_with(url, "file://" <> voice.dir(dir) <> "/")
  |> should.be_true()
  // The file is gone once sent.
  let assert "file://" <> path = url
  read(path) |> should.be_error
  test_workspace.remove_dir_recursive(dir)
}

pub fn when_speaking_fails_the_answer_goes_as_text_test() {
  let dir = test_workspace.create_temp_dir("voice-fail")
  let sent = process.new_subject()
  let charged = process.new_subject()
  let send = fn(r) {
    process.send(sent, r)
    Ok(Nil)
  }
  let failing =
    voice.Settings(
      data_dir: dir,
      speak: fn(_) { Error("Gemini answered 500") },
      admit: fn(_, _, _) {
        Ok(fn(input, output) { process.send(charged, #(input, output)) })
      },
    )
  let assert Ok(Nil) = voice.deliver(failing, "x", reply("Oi"), send)
  process.receive(sent, 100) |> should.equal(Ok(reply("Oi")))
  process.receive(charged, 100) |> should.equal(Ok(#(0, 0)))

  // A denied budget: text, nothing spoken.
  let denied = voice.Settings(..failing, admit: fn(_, _, _) { Error(Nil) })
  let assert Ok(Nil) = voice.deliver(denied, "x", reply("Oi"), send)
  process.receive(sent, 100) |> should.equal(Ok(reply("Oi")))
  test_workspace.remove_dir_recursive(dir)
}

pub fn the_estimate_grows_with_the_text_test() {
  voice.estimate("") |> should.equal(#(50, 250))
  voice.estimate(string.repeat("a", 150)) |> should.equal(#(87, 500))
}

@external(erlang, "file", "read_file")
fn read(path: String) -> Result(BitArray, a)
