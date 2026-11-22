//// The live Telegram client against a local stand-in for the Bot API: the
//// path the pilot runs, which the recorder-based tests never reach.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/telegram
import supernova/channel/channel_kit
import supernova/channel/port
import supernova/channel/registry
import supernova/config
import telegram_fake

fn client(fake: telegram_fake.Fake) -> telegram.Config {
  telegram.new_config("123:abc")
  |> telegram.with_base_url(fake.base_url)
  |> telegram.with_polling_timeout(0)
}

/// Run the polling loop in its own process, reporting to the test.
fn poll(
  fake: telegram_fake.Fake,
) -> #(
  telegram.Poller,
  process.Subject(Result(Nil, String)),
  process.Subject(Int),
) {
  let reports = process.new_subject()
  let updates = process.new_subject()
  let assert Ok(poller) = telegram.start_poller(client(fake))
  process.spawn_unlinked(fn() {
    telegram.start_polling_loop_reporting(
      poller,
      fn(outcome) { process.send(reports, outcome) },
      fn(update) { process.send(updates, update.update_id) },
    )
  })
  #(poller, reports, updates)
}

fn next_request(
  requests: process.Subject(telegram_fake.Recorded),
  method: String,
) -> telegram_fake.Recorded {
  let assert Ok(recorded) = process.receive(requests, within: 5000)
  case recorded.method == method {
    True -> recorded
    False -> next_request(requests, method)
  }
}

pub fn polling_delivers_updates_and_advances_the_offset_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  telegram_fake.queue(
    fake,
    "getUpdates",
    200,
    telegram_fake.updates_body([#(10, "oi"), #(11, "tudo bem?")]),
  )
  let #(poller, reports, updates) = poll(fake)

  process.receive(updates, within: 5000) |> should.equal(Ok(10))
  process.receive(updates, within: 5000) |> should.equal(Ok(11))
  process.receive(reports, within: 5000) |> should.equal(Ok(Ok(Nil)))

  // The first poll starts at offset 0; the next confirms what was fetched.
  let first = next_request(requests, "getUpdates")
  string.contains(first.query, "offset=0") |> should.be_true()
  let second = next_request(requests, "getUpdates")
  string.contains(second.query, "offset=12") |> should.be_true()
  telegram.request_stop(poller)
}

pub fn rejected_token_is_reported_and_backed_off_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  telegram_fake.queue(
    fake,
    "getUpdates",
    401,
    telegram_fake.error_body(401, "Unauthorized"),
  )
  let #(poller, reports, _) = poll(fake)

  let _ = next_request(requests, "getUpdates")
  process.receive(reports, within: 5000)
  |> should.equal(Ok(Error("telegram rejected the bot token")))

  // The retry waits about a second instead of hammering the API.
  process.receive(requests, within: 700) |> should.equal(Error(Nil))
  let _ = next_request(requests, "getUpdates")
  telegram.request_stop(poller)
}

pub fn rate_limit_uses_the_retry_after_telegram_sends_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  telegram_fake.queue(
    fake,
    "getUpdates",
    429,
    "{\"ok\":false,\"error_code\":429,\"description\":\"Too Many Requests: retry after 1\",\"parameters\":{\"retry_after\":1}}",
  )
  let #(poller, reports, _) = poll(fake)

  process.receive(reports, within: 5000)
  |> should.equal(Ok(Error("telegram rate limit, retry after 1s")))
  telegram.request_stop(poller)
}

pub fn api_error_keeps_telegram_description_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  telegram_fake.queue(
    fake,
    "getUpdates",
    409,
    telegram_fake.error_body(
      409,
      "Conflict: terminated by other getUpdates request",
    ),
  )
  let #(poller, reports, _) = poll(fake)

  process.receive(reports, within: 5000)
  |> should.equal(
    Ok(Error(
      "telegram api error 409: Conflict: terminated by other getUpdates request",
    )),
  )
  telegram.request_stop(poller)
}

fn live_registry(fake: telegram_fake.Fake) -> registry.ChannelRegistry {
  let base = config.default_config()
  let cfg =
    config.Config(
      ..base,
      telegram: config.TelegramConfig(
        token: Some("123:abc"),
        enabled: True,
        base_url: Some(fake.base_url),
      ),
    )
  let assert Ok(channels) =
    registry.start_channels_with_handler_and_hooks(
      cfg,
      fn(_, _) { Error(port.Ignored("test")) },
      channel_kit.StartHooks(
        ..channel_kit.no_start_hooks(),
        disable_telegram_polling: True,
      ),
    )
  channels
}

fn reply(content: String) -> port.ChannelReply {
  port.ChannelReply(
    channel_id: "42",
    content: content,
    reply_to_id: None,
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: None,
    media: [],
  )
}

fn texts(
  requests: process.Subject(telegram_fake.Recorded),
  acc: List(#(String, String)),
) -> List(#(String, String)) {
  case process.receive(requests, within: 300) {
    Ok(recorded) ->
      case recorded.method {
        "sendMessage" | "editMessageText" ->
          texts(requests, [#(recorded.method, recorded.body), ..acc])
        _ -> texts(requests, acc)
      }
    Error(_) -> list.reverse(acc)
  }
}

/// Stream from a process that owns its events subject, as the router does.
fn stream(
  channels: registry.ChannelRegistry,
  base_reply: port.ChannelReply,
) -> #(
  process.Subject(port.ChannelStreamEvent),
  process.Subject(Result(Nil, port.ChannelError)),
) {
  let handoff = process.new_subject()
  let done = process.new_subject()
  process.spawn_unlinked(fn() {
    let events = process.new_subject()
    process.send(handoff, events)
    process.send(
      done,
      registry.send_stream(channels, "telegram", base_reply, events),
    )
  })
  let assert Ok(events) = process.receive(handoff, within: 1000)
  #(events, done)
}

pub fn streamed_reply_edits_the_placeholder_into_the_answer_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  let channels = live_registry(fake)
  let #(events, done) =
    stream(channels, port.ChannelReply(..reply(""), typing: True))

  process.send(events, port.StreamUpdate(reply("Olá")))
  process.send(events, port.StreamUpdate(reply("Olá, tudo")))
  process.send(events, port.StreamComplete(reply("Olá, tudo bem?")))

  process.receive(done, within: 5000) |> should.equal(Ok(Ok(Nil)))
  let sent = texts(requests, [])
  let assert [#("sendMessage", placeholder), ..edits] = sent
  string.contains(placeholder, "Thinking...") |> should.be_true()
  let assert Ok(#("editMessageText", last)) = list.last(edits)
  string.contains(last, "Olá, tudo bem?") |> should.be_true()
  registry.stop_channels(channels)
}

pub fn repeated_update_does_not_abort_the_stream_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  let channels = live_registry(fake)
  let #(events, done) = stream(channels, reply(""))

  // Telegram answers 400 "message is not modified" to an edit that changes
  // nothing; the answer must still arrive.
  process.send(events, port.StreamUpdate(reply("Pensando")))
  process.send(events, port.StreamUpdate(reply("Pensando")))
  process.send(events, port.StreamComplete(reply("Resposta final")))

  process.receive(done, within: 5000) |> should.equal(Ok(Ok(Nil)))
  let assert Ok(#(_, last)) = list.last(texts(requests, []))
  string.contains(last, "Resposta final") |> should.be_true()
  registry.stop_channels(channels)
}

pub fn new_buttons_with_the_same_text_still_reach_telegram_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  let channels = live_registry(fake)
  let #(events, done) = stream(channels, reply(""))
  let buttons =
    port.ChannelInteractiveReply(blocks: [
      port.InteractionButtons(buttons: [
        port.ChannelButton("Sim", "confirm:sim", port.ButtonPrimary),
      ]),
    ])

  process.send(events, port.StreamUpdate(reply("Escolha")))
  process.send(
    events,
    port.StreamUpdate(
      port.ChannelReply(..reply("Escolha"), interactive: Some(buttons)),
    ),
  )
  process.send(
    events,
    port.StreamComplete(
      port.ChannelReply(..reply("Escolha"), interactive: Some(buttons)),
    ),
  )

  process.receive(done, within: 5000) |> should.equal(Ok(Ok(Nil)))
  let edits =
    texts(requests, [])
    |> list.filter(fn(sent) { sent.0 == "editMessageText" })
  list.any(edits, fn(sent) { string.contains(sent.1, "confirm:sim") })
  |> should.be_true()
  registry.stop_channels(channels)
}

pub fn base_url_must_not_send_the_token_in_cleartext_test() {
  telegram.check_base_url("https://bots.example.org") |> should.equal(Ok(Nil))
  telegram.check_base_url("http://localhost:8081") |> should.equal(Ok(Nil))
  telegram.check_base_url("http://127.0.0.1:8081") |> should.equal(Ok(Nil))
  let assert Error(_) = telegram.check_base_url("http://10.0.0.5:8081")
  let assert Error(_) =
    telegram.check_base_url("http://localhost:8081@remote.example")
  let assert Error(_) = telegram.check_base_url("ftp://localhost")
  let assert Error(_) = telegram.check_base_url("not a url")
}

pub fn cleartext_base_url_keeps_telegram_from_starting_test() {
  let base = config.default_config()
  let cfg =
    config.Config(
      ..base,
      telegram: config.TelegramConfig(
        token: Some("123:abc"),
        enabled: True,
        base_url: Some("http://10.0.0.5:8081"),
      ),
    )
  let assert Ok(channels) =
    registry.start_channels_with_handler_and_hooks(
      cfg,
      fn(_, _) { Error(port.Ignored("test")) },
      channel_kit.StartHooks(
        ..channel_kit.no_start_hooks(),
        disable_telegram_polling: True,
      ),
    )
  registry.is_channel_available(channels, "telegram") |> should.be_false()
  registry.stop_channels(channels)
}
