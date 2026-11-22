//// Telegram runtime: polling worker, update conversion, leaving
//// unauthorized groups, sending and streaming replies.

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/adapters/telegram
import supernova/channel/channel_kit
import supernova/channel/chunking
import supernova/channel/health as channel_health
import supernova/channel/port
import supernova/config
import supernova/core/access/actor as access_actor
import supernova/core/audit_log/actor as audit_actor
import supernova/core/audit_log/types as audit_types
import supernova/core/closed_group/global as closed_group_global

type TelegramWorker {
  TelegramWorker(done: process.Subject(Nil), ingress_done: process.Subject(Nil))
}

/// Telegram long polls last up to 30 seconds; a minute with no successful poll
/// means the channel is not receiving messages.
const telegram_max_silence_ms = 60_000

pub fn start_telegram_channel(
  telegram_cfg: config.TelegramConfig,
  handler: port.ChannelHandler,
  hooks: channel_kit.StartHooks,
  health: channel_health.ChannelHealth,
) -> Result(#(port.ChannelAdapter, channel_kit.StreamSendFn), String) {
  case telegram_cfg.token {
    Some(token) -> {
      let poller_config = case telegram_cfg.base_url {
        Some(base_url) ->
          telegram.with_base_url(telegram.new_config(token), base_url)
        None -> telegram.new_config(token)
      }
      let send_fn = telegram_send(poller_config, hooks)
      let stream_send_fn = telegram_stream_send(poller_config, hooks)

      use poller <- result.try(
        telegram.start_poller(poller_config)
        |> result.map_error(fn(_) { "failed to start poller actor" }),
      )

      let max_silence_ms = case hooks.disable_telegram_polling {
        True -> None
        False -> Some(telegram_max_silence_ms)
      }
      channel_health.started(
        health,
        "telegram",
        max_silence_ms,
        channel_health.now_ms(),
      )
      let worker =
        start_telegram_worker(
          poller,
          handler,
          send_fn,
          stream_send_fn,
          hooks,
          poller_config,
          fn(outcome) {
            channel_health.report(
              health,
              "telegram",
              outcome,
              channel_health.now_ms(),
            )
          },
        )

      Ok(#(
        port.ChannelAdapter(
          name: "telegram",
          send: send_fn,
          stop_ingress: fn() {
            telegram.request_stop(poller)
            stop_telegram_ingress(worker, poller_config.polling_timeout)
          },
          stop: fn() {
            telegram.request_stop(poller)
            stop_telegram_worker(worker, poller_config.polling_timeout)
            Nil
          },
        ),
        stream_send_fn,
      ))
    }
    None -> Error("enabled but no token configured")
  }
}

fn start_telegram_worker(
  poller: telegram.Poller,
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: channel_kit.StreamSendFn,
  hooks: channel_kit.StartHooks,
  telegram_config: telegram.Config,
  report_poll: fn(Result(Nil, String)) -> Nil,
) -> TelegramWorker {
  let done = process.new_subject()
  let ingress_done = process.new_subject()

  let _ =
    process.spawn_unlinked(fn() {
      case hooks.disable_telegram_polling {
        True -> {
          hooks.telegram_updates
          |> list.each(fn(update) {
            dispatch_telegram_update(
              handler,
              send_fn,
              stream_send_fn,
              update,
              telegram_config,
              hooks.leave_group,
              hooks.leave_retry_ms,
              hooks.registry_id,
              hooks.turn_hard_timeout_ms,
            )
          })
          process.send(ingress_done, Nil)
        }
        False -> {
          hooks.telegram_updates
          |> list.each(fn(update) {
            dispatch_telegram_update(
              handler,
              send_fn,
              stream_send_fn,
              update,
              telegram_config,
              hooks.leave_group,
              hooks.leave_retry_ms,
              hooks.registry_id,
              hooks.turn_hard_timeout_ms,
            )
          })

          let _ =
            telegram.start_polling_loop_reporting(
              poller,
              report_poll,
              fn(update) {
                dispatch_telegram_update(
                  handler,
                  send_fn,
                  stream_send_fn,
                  update,
                  telegram_config,
                  hooks.leave_group,
                  hooks.leave_retry_ms,
                  hooks.registry_id,
                  hooks.turn_hard_timeout_ms,
                )
              },
            )
          process.send(ingress_done, Nil)
          Nil
        }
      }

      process.send(done, Nil)
    })

  TelegramWorker(done: done, ingress_done: ingress_done)
}

fn stop_telegram_ingress(worker: TelegramWorker, polling_timeout: Int) -> Nil {
  let wait_ms = { polling_timeout + 5 } * 1000
  let _ = process.receive(worker.ingress_done, within: wait_ms)
  Nil
}

fn stop_telegram_worker(worker: TelegramWorker, polling_timeout: Int) -> Nil {
  let wait_ms = { polling_timeout + 5 } * 1000
  let _ = process.receive(worker.done, within: wait_ms)
  Nil
}

fn dispatch_telegram_update(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: channel_kit.StreamSendFn,
  update: telegram.Update,
  telegram_config: telegram.Config,
  leave_group: Option(fn(String) -> Bool),
  leave_retry_ms: List(Int),
  registry_id: String,
  turn_hard_timeout_ms: Int,
) -> Nil {
  case update.my_chat_member {
    Some(member) ->
      maybe_leave_unauthorized_group(
        telegram_config,
        member,
        leave_group,
        leave_retry_ms,
      )
    None -> Nil
  }
  case telegram_update_to_inbound(update) {
    Ok(inbound) ->
      channel_kit.dispatch_inbound(
        handler,
        send_fn,
        stream_send_fn,
        inbound,
        registry_id,
        turn_hard_timeout_ms,
      )
    Error(_) -> Nil
  }
}

fn maybe_leave_unauthorized_group(
  telegram_config: telegram.Config,
  member: telegram.ChatMemberUpdated,
  leave_group: Option(fn(String) -> Bool),
  leave_retry_ms: List(Int),
) -> Nil {
  let is_group = case member.chat.chat_type {
    telegram.GroupChat | telegram.SupergroupChat -> True
    _ -> False
  }
  let joined = case member.new_status {
    "member" | "administrator" -> True
    _ -> False
  }
  let chat_key = "telegram:" <> member.chat.id
  case is_group && joined {
    True ->
      case closed_group_global.chat_authorized_result(chat_key) {
        Ok(True) -> Nil
        Ok(False) ->
          leave_confirmed(
            telegram_config,
            member.chat.id,
            chat_key,
            leave_group,
            leave_retry_ms,
          )
        Error(_) -> {
          io.println(
            "warn: access lookup failed while checking chat " <> chat_key,
          )
          record_chat_check_failed(chat_key)
          schedule_leave_recheck(
            telegram_config,
            member,
            leave_group,
            leave_retry_ms,
          )
        }
      }
    False -> Nil
  }
}

fn leave_confirmed(
  telegram_config: telegram.Config,
  chat_id: String,
  chat_key: String,
  leave_group: Option(fn(String) -> Bool),
  retry_delays: List(Int),
) -> Nil {
  case leave_group {
    Some(leave) ->
      case leave(chat_id) {
        True -> record_leave_audit(chat_key)
        False ->
          schedule_leave_retry(
            telegram_config,
            chat_id,
            chat_key,
            leave_group,
            retry_delays,
          )
      }
    None ->
      case telegram.leave_chat(telegram_config, chat_id) {
        Ok(_) -> record_leave_audit(chat_key)
        Error(_) ->
          schedule_leave_retry(
            telegram_config,
            chat_id,
            chat_key,
            leave_group,
            retry_delays,
          )
      }
  }
}

fn schedule_leave_retry(
  telegram_config: telegram.Config,
  chat_id: String,
  chat_key: String,
  leave_group: Option(fn(String) -> Bool),
  retry_delays: List(Int),
) -> Nil {
  case retry_delays {
    [] -> {
      record_leave_failed(chat_key)
      alert_admins(
        "Não consegui sair do grupo não autorizado " <> chat_key <> ".",
      )
      Nil
    }
    [delay, ..rest] -> {
      let _ =
        process.spawn_unlinked(fn() {
          process.sleep(delay)
          // An admin may have authorized the group during the wait.
          case closed_group_global.chat_authorized_result(chat_key) {
            Ok(True) -> Nil
            Ok(False) ->
              leave_confirmed(
                telegram_config,
                chat_id,
                chat_key,
                leave_group,
                rest,
              )
            Error(_) -> {
              record_chat_check_failed(chat_key)
              schedule_leave_retry(
                telegram_config,
                chat_id,
                chat_key,
                leave_group,
                rest,
              )
            }
          }
        })
      Nil
    }
  }
}

fn schedule_leave_recheck(
  telegram_config: telegram.Config,
  member: telegram.ChatMemberUpdated,
  leave_group: Option(fn(String) -> Bool),
  retry_delays: List(Int),
) -> Nil {
  process.spawn_unlinked(fn() {
    process.sleep(30_000)
    recheck_leave(telegram_config, member, leave_group, retry_delays)
  })
  Nil
}

fn recheck_leave(
  telegram_config: telegram.Config,
  member: telegram.ChatMemberUpdated,
  leave_group: Option(fn(String) -> Bool),
  retry_delays: List(Int),
) -> Nil {
  let chat_key = "telegram:" <> member.chat.id
  case closed_group_global.chat_authorized_result(chat_key) {
    Ok(True) -> Nil
    Ok(False) ->
      leave_confirmed(
        telegram_config,
        member.chat.id,
        chat_key,
        leave_group,
        retry_delays,
      )
    Error(_) -> {
      io.println(
        "warn: access lookup failed again while checking chat " <> chat_key,
      )
      record_chat_check_failed(chat_key)
    }
  }
}

fn record_leave_failed(chat_key: String) -> Nil {
  case closed_group_global.get_audit() {
    None -> Nil
    Some(audit) ->
      audit_actor.log_entry(
        audit,
        audit_types.denied_entry(
          closed_group_global.now(),
          "telegram",
          "leave_failed",
          chat_key,
          "Telegram did not confirm the leave",
        ),
      )
  }
}

fn alert_admins(text: String) -> Nil {
  case closed_group_global.get_runtime() {
    None -> Nil
    Some(runtime) ->
      case access_actor.try_list_admins(runtime.access) {
        Ok([]) ->
          io.println(
            "warn: alert dropped because no effective admins are configured",
          )
        Ok(admins) ->
          list.each(admins, fn(admin) { runtime.send_alert(admin, text) })
        Error(_) -> {
          io.println("warn: alert dropped because access is unavailable")
          record_alert_dropped("access unavailable")
        }
      }
  }
}

fn record_alert_dropped(reason: String) -> Nil {
  case closed_group_global.get_audit() {
    None -> Nil
    Some(audit) ->
      audit_actor.log_entry(
        audit,
        audit_types.denied_entry(
          closed_group_global.now(),
          "system",
          "alert_dropped",
          "admins",
          reason,
        ),
      )
  }
}

fn record_chat_check_failed(chat_key: String) -> Nil {
  case closed_group_global.get_audit() {
    None -> Nil
    Some(audit) ->
      audit_actor.log_entry(
        audit,
        audit_types.denied_entry(
          closed_group_global.now(),
          "telegram",
          "chat_check_failed",
          chat_key,
          "access lookup unavailable",
        ),
      )
  }
}

fn record_leave_audit(chat_key: String) -> Nil {
  case closed_group_global.get_audit() {
    None -> Nil
    Some(audit) ->
      audit_actor.log_entry(
        audit,
        audit_types.denied_entry(
          closed_group_global.now(),
          "telegram",
          "chat_denied",
          chat_key,
          "left unauthorized group",
        ),
      )
  }
}

fn telegram_update_to_inbound(
  update: telegram.Update,
) -> Result(port.ChannelInbound, port.ChannelError) {
  case update.message {
    Some(message) ->
      case message.from {
        Some(from) ->
          Ok(
            port.inbound_message(port.ChannelMessage(
              id: int.to_string(message.message_id),
              channel: "telegram",
              channel_id: message.chat.id,
              user_id: from.id,
              username: telegram_username(from),
              content: telegram_message_content(message),
              is_bot: from.is_bot,
              reply_to_id: telegram_reply_to_id(message.reply_to_message_id),
            )),
          )
        None -> Error(port.Ignored("telegram message missing sender"))
      }
    None ->
      case update.callback_query {
        Some(callback) ->
          case
            telegram_callback_query_to_inbound(
              callback,
              telegram_callback_query_message_id(callback.message),
            )
          {
            Ok(inbound) -> Ok(inbound)
            Error(error) -> Error(error)
          }
        None -> Error(port.Ignored("unsupported telegram update"))
      }
  }
}

fn telegram_callback_query_to_inbound(
  callback: telegram.CallbackQuery,
  source_message_id: Option(String),
) -> Result(port.ChannelInbound, port.ChannelError) {
  let telegram.CallbackQuery(
    id: callback_id,
    from: user,
    message: message,
    data: data,
    ..,
  ) = callback

  case message, data {
    Some(message), Some(callback_data) -> {
      let #(action_id, values) = telegram_callback_action(callback_data)

      Ok(
        port.inbound_interaction(port.ChannelInteractionMessage(
          channel: "telegram",
          channel_id: message.chat.id,
          user_id: user.id,
          username: telegram_username(user),
          is_bot: user.is_bot,
          event: port.ChannelInteractionEvent(
            id: callback_id,
            action_id: action_id,
            values: values,
            source_message_id: source_message_id,
          ),
        )),
      )
    }
    None, _ -> Error(port.Ignored("telegram callback query missing message"))
    _, None -> Error(port.Ignored("telegram callback query missing data"))
  }
}

fn telegram_callback_query_message_id(
  message: Option(telegram.Message),
) -> Option(String) {
  case message {
    Some(message) -> Some(int.to_string(message.message_id))
    None -> None
  }
}

fn telegram_callback_action(callback_data: String) -> #(String, List(String)) {
  let model_select_prefix = "picker_model_select:"

  case string.starts_with(callback_data, model_select_prefix) {
    True -> #("picker_model_select", [
      string.drop_start(callback_data, string.length(model_select_prefix)),
    ])
    False -> #(callback_data, [])
  }
}

fn telegram_username(user: telegram.User) -> String {
  case user.username {
    Some(username) -> username
    None -> user.first_name
  }
}

fn telegram_message_content(message: telegram.Message) -> String {
  case message.text {
    Some(text) -> text
    None ->
      case message.caption {
        Some(caption) -> caption
        None -> ""
      }
  }
}

fn telegram_reply_to_id(reply_to_message_id: Option(Int)) -> Option(String) {
  case reply_to_message_id {
    Some(message_id) -> Some(int.to_string(message_id))
    None -> None
  }
}

fn telegram_send(
  telegram_config: telegram.Config,
  hooks: channel_kit.StartHooks,
) -> fn(port.ChannelReply) -> Result(Nil, port.ChannelError) {
  fn(reply: port.ChannelReply) {
    let replies = chunking.split_reply(reply, chunking.telegram_max_length)

    case hooks.outbound_records {
      Some(recorder) ->
        channel_kit.record_reply_for_test(recorder, "telegram", replies)
      None ->
        channel_kit.send_chunked_replies(replies, fn(part) {
          case telegram_send_message(telegram_config, part) {
            Ok(_) -> Ok(Nil)
            Error(error) -> Error(error)
          }
        })
    }
  }
}

fn telegram_stream_send(
  telegram_config: telegram.Config,
  hooks: channel_kit.StartHooks,
) -> channel_kit.StreamSendFn {
  fn(
    base_reply: port.ChannelReply,
    events: process.Subject(port.ChannelStreamEvent),
  ) {
    let keepalive_ms =
      channel_kit.normalize_typing_keepalive_ms(hooks.typing_keepalive_ms)
    case hooks.outbound_records {
      Some(recorder) ->
        channel_kit.record_stream_for_test(
          recorder,
          "telegram",
          base_reply,
          events,
          keepalive_ms,
          hooks.stream_timeout_ms,
        )
      None ->
        stream_telegram_reply(telegram_config, base_reply, events, keepalive_ms)
    }
  }
}

fn telegram_trigger_typing(
  telegram_config: telegram.Config,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  case
    telegram.send_chat_action(
      telegram_config,
      reply.channel_id,
      telegram.TypingAction,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(map_telegram_send_error(error))
  }
}

fn telegram_send_message(
  telegram_config: telegram.Config,
  reply: port.ChannelReply,
) -> Result(telegram.SentMessage, port.ChannelError) {
  case telegram_send_options(reply) {
    Error(error) -> Error(error)
    Ok(send_options) -> {
      let typing_result = case reply.typing {
        True -> telegram_trigger_typing(telegram_config, reply)
        False -> Ok(Nil)
      }

      case typing_result {
        Error(error) -> Error(error)
        Ok(_) ->
          case parse_optional_telegram_message_id(reply.edit_message_id) {
            Error(error) -> Error(error)
            Ok(edit_message_id) ->
              case
                telegram.send_or_edit_message(
                  telegram_config,
                  reply.channel_id,
                  reply.content,
                  edit_message_id,
                  send_options,
                )
              {
                Ok(message) -> Ok(message)
                Error(error) -> Error(map_telegram_send_error(error))
              }
          }
      }
    }
  }
}

fn telegram_send_options(
  reply: port.ChannelReply,
) -> Result(telegram.SendMessageOptions, port.ChannelError) {
  let options = telegram.new_send_options()

  let options = case reply.interactive {
    Some(interactive) ->
      telegram.with_reply_markup(options, telegram_reply_markup(interactive))
    None -> options
  }

  let options_result = case reply.reply_to_id {
    Some(reply_to_id) ->
      case int.parse(reply_to_id) {
        Ok(message_id) -> Ok(telegram.with_reply_to(options, message_id))
        Error(_) ->
          Error(port.SendFailed("invalid telegram reply_to_id: " <> reply_to_id))
      }
    None -> Ok(options)
  }

  case options_result, reply.thread_id {
    Ok(current_options), Some(thread_id) ->
      case int.parse(thread_id) {
        Ok(message_thread_id) ->
          Ok(telegram.with_message_thread_id(current_options, message_thread_id))
        Error(_) ->
          Error(port.SendFailed("invalid telegram thread_id: " <> thread_id))
      }
    Ok(current_options), None -> Ok(current_options)
    Error(error), _ -> Error(error)
  }
}

fn stream_telegram_reply(
  telegram_config: telegram.Config,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
  keepalive_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let placeholder =
    port.ChannelReply(..base_reply, content: "Thinking...", typing: True)

  use placeholder_message <- result.try(telegram_send_message(
    telegram_config,
    placeholder,
  ))

  consume_telegram_stream_events(
    telegram_config,
    base_reply,
    events,
    placeholder_message.message_id,
    "",
    channel_kit.stream_timeout_ms,
    keepalive_ms,
  )
}

fn consume_telegram_stream_events(
  telegram_config: telegram.Config,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
  message_id: Int,
  last_content: String,
  remaining_ms: Int,
  keepalive_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let wait_ms = channel_kit.stream_wait_ms(remaining_ms, keepalive_ms)

  case process.receive(events, within: wait_ms) {
    Ok(port.StreamUpdate(reply)) ->
      case
        reply.content != last_content
        && channel_kit.stream_update_fits("telegram", reply.content)
      {
        True -> {
          let next_reply =
            port.ChannelReply(
              ..reply,
              edit_message_id: Some(int.to_string(message_id)),
            )
          // Telegram refuses an edit that changes nothing; that is not a
          // reason to drop the rest of the answer.
          use _ <- result.try(
            case telegram_send_message(telegram_config, next_reply) {
              Error(error) ->
                case channel_kit.is_message_not_modified(error) {
                  True -> Ok(Nil)
                  False -> Error(error)
                }
              Ok(_) -> Ok(Nil)
            },
          )
          consume_telegram_stream_events(
            telegram_config,
            base_reply,
            events,
            message_id,
            reply.content,
            remaining_ms,
            keepalive_ms,
          )
        }
        False ->
          consume_telegram_stream_events(
            telegram_config,
            base_reply,
            events,
            message_id,
            last_content,
            remaining_ms,
            keepalive_ms,
          )
      }
    Ok(port.StreamComplete(reply)) ->
      case reply.content == last_content {
        True -> Ok(Nil)
        False ->
          channel_kit.finish_stream_in_parts(
            reply,
            int.to_string(message_id),
            chunking.telegram_max_length,
            fn(part) {
              telegram_send_message(telegram_config, part)
              |> result.map(fn(_) { Nil })
            },
          )
      }
    Ok(port.StreamFailure(error)) -> Error(error)
    Error(_) ->
      case remaining_ms <= wait_ms {
        True -> {
          let timeout_reply =
            port.ChannelReply(
              ..base_reply,
              content: "Streaming timed out",
              edit_message_id: Some(int.to_string(message_id)),
              typing: False,
            )
          let _ = telegram_send_message(telegram_config, timeout_reply)
          Error(port.SendFailed("stream timed out"))
        }
        False -> {
          use _ <- result.try(telegram_trigger_typing(
            telegram_config,
            base_reply,
          ))
          consume_telegram_stream_events(
            telegram_config,
            base_reply,
            events,
            message_id,
            last_content,
            remaining_ms - wait_ms,
            keepalive_ms,
          )
        }
      }
  }
}

fn telegram_reply_markup(
  interactive: port.ChannelInteractiveReply,
) -> telegram.ReplyMarkup {
  interactive.blocks
  |> list.fold([], fn(rows, block) {
    case block {
      port.InteractionText(_) -> rows
      port.InteractionButtons(buttons) -> [
        list.map(buttons, telegram_button),
        ..rows
      ]
      port.InteractionSelect(action_id, _, options) -> [
        list.map(options, fn(option) {
          telegram.inline_keyboard_button(
            port.select_option_label(option),
            action_id <> ":" <> port.select_option_value(option),
          )
        }),
        ..rows
      ]
    }
  })
  |> list.reverse
  |> telegram.inline_keyboard
}

fn telegram_button(
  button: port.ChannelButton,
) -> telegram.InlineKeyboardButton {
  telegram.inline_keyboard_button(
    port.button_label(button),
    port.button_action_id(button),
  )
}

fn parse_optional_telegram_message_id(
  message_id: Option(String),
) -> Result(Option(Int), port.ChannelError) {
  case message_id {
    None -> Ok(None)
    Some(value) ->
      case int.parse(value) {
        Ok(parsed) -> Ok(Some(parsed))
        Error(_) ->
          Error(port.SendFailed("invalid telegram edit_message_id: " <> value))
      }
  }
}

fn map_telegram_send_error(error: telegram.TelegramError) -> port.ChannelError {
  case error {
    telegram.RateLimitError(retry_after) ->
      port.RateLimited(retry_after_seconds: retry_after)
    telegram.InvalidTokenError -> port.NotConnected
    _ -> port.SendFailed(telegram_error_to_string(error))
  }
}

fn telegram_error_to_string(error: telegram.TelegramError) -> String {
  case error {
    telegram.HttpError(message) -> message
    telegram.JsonDecodeError(message) -> message
    telegram.ApiError(code, description) ->
      "api error " <> int.to_string(code) <> ": " <> description
    telegram.RateLimitError(retry_after) ->
      "rate limited for " <> int.to_string(retry_after) <> " seconds"
    telegram.InvalidTokenError -> "invalid token"
    telegram.NetworkError(message) -> message
    telegram.TimeoutError -> "timeout"
    telegram.MessageTooLongError -> "message too long"
    telegram.InvalidParseModeError -> "invalid parse mode"
  }
}
