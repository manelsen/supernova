import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/channel/chunking
import supernova/channel/port

pub fn split_reply_short_content_test() {
  let reply =
    port.ChannelReply(
      channel_id: "channel-1",
      content: "short reply",
      reply_to_id: None,
      thread_id: None,
      typing: True,
      edit_message_id: None,
      interactive: None,
      media: [],
    )

  let chunks = chunking.split_reply(reply, 50)

  list.length(chunks) |> should.equal(1)
  chunks |> should.equal([reply])
}

pub fn split_reply_adds_continuation_without_breaking_words_test() {
  let reply =
    port.ChannelReply(
      channel_id: "channel-1",
      content: "alpha beta gamma delta epsilon zeta eta theta",
      reply_to_id: None,
      thread_id: None,
      typing: False,
      edit_message_id: None,
      interactive: None,
      media: [],
    )

  let chunks = chunking.split_reply(reply, 24)

  should.equal(list.length(chunks) > 1, True)

  case chunks {
    [first, second, third, ..] -> {
      should.equal(string.length(first.content) <= 24, True)
      should.equal(string.length(second.content) <= 24, True)
      should.equal(string.length(third.content) <= 24, True)

      string.ends_with(first.content, " ") |> should.equal(False)
      string.starts_with(second.content, chunking.continuation_prefix())
      |> should.equal(True)
      string.starts_with(third.content, chunking.continuation_prefix())
      |> should.equal(True)
    }
    _ -> should.fail()
  }
}

pub fn split_reply_reopens_fenced_markdown_blocks_test() {
  let code = string.repeat("value = 42\n", 8)
  let reply =
    port.ChannelReply(
      channel_id: "channel-1",
      content: "Before\n```gleam\n" <> code <> "```\nAfter",
      reply_to_id: None,
      thread_id: None,
      typing: False,
      edit_message_id: None,
      interactive: None,
      media: [],
    )

  let chunks = chunking.split_reply(reply, 36)

  should.equal(list.length(chunks) > 1, True)

  chunks
  |> list.each(fn(chunk) {
    should.equal(string.length(chunk.content) <= 36, True)
    count_fences(chunk.content)
    |> remainder(2)
    |> should.equal(0)
  })
}

fn count_fences(text: String) -> Int {
  case string.split(text, "```") {
    [] -> 0
    parts -> list.length(parts) - 1
  }
}

fn remainder(value: Int, divisor: Int) -> Int {
  value % divisor
}
