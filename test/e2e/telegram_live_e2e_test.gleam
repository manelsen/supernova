//// The live Telegram path end to end against a local Bot API: leaving
//// unauthorized groups, admin alerts, buttons and send errors.

import e2e/e2e_support as support
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/telegram
import supernova/channel/channel_kit
import supernova/channel/port
import supernova/channel/registry
import supernova/config
import supernova/core/access/actor as access_actor
import supernova/core/closed_group/global as closed_group_global
import telegram_fake

fn cfg(fake: telegram_fake.Fake) -> config.Config {
  let base = support.channel_config()
  config.Config(
    ..base,
    access: support.access_config(["telegram:1"], ["telegram:123"]),
    telegram: config.TelegramConfig(
      token: Some("123:abc"),
      enabled: True,
      base_url: Some(fake.base_url),
    ),
  )
}

fn start(
  cfg: config.Config,
  updates: List(telegram.Update),
  retry_ms: List(Int),
  recheck_ms: Int,
) -> registry.ChannelRegistry {
  let assert Ok(channels) =
    registry.start_channels_with_handler_and_hooks(
      cfg,
      support.telegram_handler(support.mock_config()),
      channel_kit.StartHooks(
        ..channel_kit.no_start_hooks(),
        telegram_updates: updates,
        disable_telegram_polling: True,
        leave_retry_ms: retry_ms,
        leave_recheck_ms: recheck_ms,
      ),
    )
  channels
}

fn next(
  requests: process.Subject(telegram_fake.Recorded),
  method: String,
  within: Int,
) -> Result(telegram_fake.Recorded, Nil) {
  case process.receive(requests, within: within) {
    Ok(recorded) ->
      case recorded.method == method {
        True -> Ok(recorded)
        False -> next(requests, method, within)
      }
    Error(_) -> Error(Nil)
  }
}

pub fn unauthorized_group_is_left_through_the_bot_api_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  support.with_runtime(cfg(fake), fn() {
    let channels =
      start(
        cfg(fake),
        [support.telegram_chat_member_update("-1009", "member")],
        [5, 5],
        30_000,
      )
    let assert Ok(left) = next(requests, "leaveChat", 3000)
    string.contains(left.body, "-1009") |> should.be_true()
    registry.stop_channels(channels)
  })
}

pub fn failed_leave_alerts_the_admins_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  let error = telegram_fake.error_body(400, "Bad Request: chat not found")
  telegram_fake.queue(fake, "leaveChat", 400, error)
  telegram_fake.queue(fake, "leaveChat", 400, error)
  telegram_fake.queue(fake, "leaveChat", 400, error)
  support.with_runtime(cfg(fake), fn() {
    let alerts = process.new_subject()
    closed_group_global.set_alert_sender(fn(admin, text) {
      process.send(alerts, #(admin, text))
    })
    let channels =
      start(
        cfg(fake),
        [support.telegram_chat_member_update("-1010", "member")],
        [5, 5],
        30_000,
      )
    let assert Ok(#(admin, text)) = process.receive(alerts, within: 3000)
    admin |> should.equal("telegram:1")
    text
    |> should.equal("Não consegui sair do grupo não autorizado telegram:-1010.")
    registry.stop_channels(channels)
  })
}

pub fn group_is_rechecked_after_access_comes_back_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  support.with_runtime(cfg(fake), fn() {
    let assert Some(runtime) = closed_group_global.get_runtime()
    let access = runtime.access
    // A subject owned by this test never answers, so the first lookup fails.
    let unresponsive: access_actor.AccessActor = process.new_subject()
    closed_group_global.set_access(unresponsive)

    let channels =
      start(
        cfg(fake),
        [support.telegram_chat_member_update("-1011", "member")],
        [5, 5],
        2000,
      )
    // No leave while access is unavailable.
    next(requests, "leaveChat", 1000) |> should.equal(Error(Nil))
    closed_group_global.set_access(access)

    let assert Ok(left) = next(requests, "leaveChat", 5000)
    string.contains(left.body, "-1011") |> should.be_true()
    registry.stop_channels(channels)
  })
}

fn send(
  channels: registry.ChannelRegistry,
  interactive: option.Option(port.ChannelInteractiveReply),
) -> Result(Nil, port.ChannelError) {
  registry.send(
    channels,
    "telegram",
    port.ChannelReply(
      channel_id: "42",
      content: "Escolha",
      reply_to_id: None,
      thread_id: None,
      typing: False,
      edit_message_id: None,
      interactive: interactive,
      media: [],
    ),
  )
}

pub fn buttons_and_selects_become_an_inline_keyboard_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  let channels = start(cfg(fake), [], [5], 30_000)
  let keyboard =
    port.interactive_reply([
      port.text_block("Provider: Mistral"),
      port.buttons_block([
        port.button("Mistral", "picker_provider:mistral", port.ButtonPrimary),
      ]),
      port.select_block(
        action_id: "picker_model_select",
        placeholder: None,
        options: [
          port.select_option("deepseek", "mistral|deepseek-v4-1-flash-1017"),
        ],
      ),
    ])

  send(channels, Some(keyboard)) |> should.equal(Ok(Nil))
  let assert Ok(sent) = next(requests, "sendMessage", 3000)
  string.contains(sent.body, "\"callback_data\":\"picker_provider:mistral\"")
  |> should.be_true()
  string.contains(
    sent.body,
    "\"callback_data\":\"m:mistral|deepseek-v4-1-flash-1017\"",
  )
  |> should.be_true()
  registry.stop_channels(channels)
}

pub fn a_button_too_long_for_telegram_does_not_sink_the_message_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  let channels = start(cfg(fake), [], [5], 30_000)
  let long_model =
    "openrouter|meta-llama/llama-3.3-70b-instruct:free-extended-preview"
  let keyboard =
    port.interactive_reply([
      port.select_block(
        action_id: "picker_model_select",
        placeholder: None,
        options: [
          port.select_option("curto", "mistral|small"),
          port.select_option("longo", long_model),
        ],
      ),
    ])

  send(channels, Some(keyboard)) |> should.equal(Ok(Nil))
  let assert Ok(sent) = next(requests, "sendMessage", 3000)
  string.contains(sent.body, "mistral|small") |> should.be_true()
  string.contains(sent.body, long_model) |> should.be_false()
  registry.stop_channels(channels)
}

pub fn send_errors_map_to_channel_errors_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  let channels = start(cfg(fake), [], [5], 30_000)
  telegram_fake.queue(
    fake,
    "sendMessage",
    403,
    telegram_fake.error_body(403, "Forbidden: bot was blocked by the user"),
  )
  telegram_fake.queue(
    fake,
    "sendMessage",
    429,
    "{\"ok\":false,\"error_code\":429,\"description\":\"Too Many Requests: retry after 3\",\"parameters\":{\"retry_after\":3}}",
  )
  telegram_fake.queue(
    fake,
    "sendMessage",
    401,
    telegram_fake.error_body(401, "Unauthorized"),
  )

  send(channels, None)
  |> should.equal(
    Error(port.SendFailed(
      "api error 403: Forbidden: bot was blocked by the user",
    )),
  )
  send(channels, None)
  |> should.equal(Error(port.RateLimited(retry_after_seconds: 3)))
  send(channels, None) |> should.equal(Error(port.NotConnected))
  registry.stop_channels(channels)
}

fn inbound(chat: String, content: String) -> port.ChannelInbound {
  port.inbound_message(port.ChannelMessage(
    id: "agenda-" <> content,
    channel: "telegram",
    channel_id: chat,
    user_id: chat,
    username: "",
    content: content,
    is_bot: False,
    reply_to_id: None,
  ))
}

pub fn injected_inbound_is_answered_through_the_bot_api_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  let channels = start(cfg(fake), [], [5], 30_000)
  let handler = fn(inbound, _events) {
    let assert port.InboundMessage(message) = inbound
    Ok(
      port.ImmediateReply(port.reply(
        to: message,
        content: "Lembrete: " <> message.content,
      )),
    )
  }

  registry.inject(channels, handler, inbound("42", "beber água"))
  |> should.equal(Ok(Nil))
  let assert Ok(sent) = next(requests, "sendMessage", 3000)
  string.contains(sent.body, "Lembrete: beber água") |> should.be_true()
  registry.stop_channels(channels)
}

pub fn inject_into_an_unregistered_channel_is_an_error_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  let channels = start(cfg(fake), [], [5], 30_000)
  let assert Error(port.SendFailed(_)) =
    registry.inject(
      channels,
      fn(_, _) { Error(port.Ignored("unused")) },
      port.inbound_message(port.ChannelMessage(
        id: "x",
        channel: "matrix",
        channel_id: "1",
        user_id: "1",
        username: "",
        content: "oi",
        is_bot: False,
        reply_to_id: None,
      )),
    )
  registry.stop_channels(channels)
}

pub fn injected_turn_waits_for_the_turn_already_in_the_chat_test() {
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  let channels = start(cfg(fake), [], [5], 30_000)
  let started = process.new_subject()
  let handler = fn(inbound, _events) {
    let assert port.InboundMessage(message) = inbound
    // The handler owns its gate; the test opens it.
    let gate = process.new_subject()
    process.send(started, #(message.content, gate))
    let _ = process.receive(gate, within: 5000)
    Ok(port.ImmediateReply(port.reply(to: message, content: "ok")))
  }

  let assert Ok(Nil) =
    registry.inject(channels, handler, inbound("42", "pessoa"))
  let assert Ok(#("pessoa", first_gate)) =
    process.receive(started, within: 3000)
  let assert Ok(Nil) =
    registry.inject(channels, handler, inbound("42", "agenda"))

  // Same chat: the agenda turn does not start while the first one runs.
  process.receive(started, within: 300)
  |> option.from_result
  |> should.equal(None)
  process.send(first_gate, Nil)
  let assert Ok(#("agenda", second_gate)) =
    process.receive(started, within: 3000)
  process.send(second_gate, Nil)
  registry.stop_channels(channels)
}
