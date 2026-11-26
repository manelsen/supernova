//// The Matrix stream against a local homeserver: a long reply is split into
//// parts that fit in an event, as Telegram and Discord do.

import discord_fake
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/adapters/matrix_channel
import supernova/channel/chunking
import supernova/channel/port

fn reply(content: String) -> port.ChannelReply {
  port.ChannelReply(
    channel_id: "!sala:exemplo.org",
    content: content,
    reply_to_id: None,
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: None,
    media: [],
  )
}

fn body_of(request: discord_fake.ApiRequest) -> String {
  let assert Ok(body) =
    json.parse(request.body, decode.at(["body"], decode.string))
  body
}

/// Every request the homeserver got, until it is quiet.
fn drain(api: discord_fake.Api, acc: List(discord_fake.ApiRequest)) {
  case process.receive(api.requests, 500) {
    Ok(request) -> drain(api, [request, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

pub fn a_long_stream_is_sent_in_parts_that_fit_test() {
  let api = discord_fake.start_api()
  int.range(from: 1, to: 13, with: Nil, run: fn(_, n) {
    discord_fake.script(
      api,
      "/_matrix/",
      200,
      "{\"event_id\":\"$e" <> int.to_string(n) <> "\"}",
    )
  })
  let long = string.repeat("palavra ", 2500)
  let events = process.new_subject()
  process.send(events, port.StreamComplete(reply(long)))
  matrix_channel.stream_matrix_reply(
    api.base_url,
    "token",
    reply(""),
    events,
    0,
  )
  |> should.equal(Ok(Nil))
  let requests = drain(api, [])
  // The placeholder, the edit with the first part, and new messages.
  { list.length(requests) > 2 } |> should.be_true()
  list.each(requests, fn(request) {
    { string.length(body_of(request)) <= chunking.matrix_max_length + 2 }
    |> should.be_true()
  })
}
