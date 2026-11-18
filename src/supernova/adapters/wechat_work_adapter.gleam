//// WeChat Work Adapter — native adapter for robot webhook delivery.
////
//// This adapter targets the webhook-based flow used by WeCom robots for
//// outbound messages. Inbound parsing expects a post-decryption JSON payload
//// produced by the HTTP edge before it reaches the shared router.

import gleam/dynamic/decode
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port
import supernova/channel/session.{type SessionResolver, without_manager}

pub fn start(
  webhook_url: String,
  _handler: port.ChannelHandler,
) -> Result(port.ChannelAdapter, String) {
  let send_fn = fn(reply: port.ChannelReply) -> Result(Nil, port.ChannelError) {
    do_send(webhook_url, reply)
  }

  Ok(
    port.ChannelAdapter(
      name: "wechat_work",
      send: send_fn,
      stop: fn() { Nil },
      stop_ingress: fn() { Nil },
    ),
  )
}

pub fn parse_event(
  event_json: String,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case json.parse(event_json, wechat_work_event_decoder()) {
    Ok(event) -> normalize_event(event)
    Error(_) -> Error(port.SendFailed("invalid JSON"))
  }
}

pub fn build_reply_payload(
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  Ok(
    json.object([
      #("msgtype", json.string("text")),
      #("text", json.object([#("content", json.string(reply.content))])),
    ])
    |> json.to_string,
  )
}

pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  "wechat_work:" <> msg.channel_id <> ":" <> msg.user_id
}

pub fn session_resolver() -> SessionResolver {
  without_manager("wechat_work")
}

type WechatWorkEvent {
  WechatWorkEvent(
    msg_id: String,
    chat_id: String,
    msg_type: String,
    from: WechatWorkSender,
    text: Option(WechatWorkText),
    reply_to_msgid: Option(String),
  )
}

type WechatWorkSender {
  WechatWorkSender(user_id: String, name: String)
}

type WechatWorkText {
  WechatWorkText(content: String)
}

fn wechat_work_event_decoder() -> decode.Decoder(WechatWorkEvent) {
  use msg_id <- decode.field("msgid", decode.string)
  use chat_id <- decode.field("chatid", decode.string)
  use msg_type <- decode.field("msgtype", decode.string)
  use from <- decode.field("from", wechat_work_sender_decoder())
  use text <- decode.optional_field(
    "text",
    None,
    wechat_work_text_decoder() |> decode.map(Some),
  )
  use reply_to_msgid <- decode.optional_field(
    "reply_to_msgid",
    None,
    decode.string |> decode.map(Some),
  )
  decode.success(WechatWorkEvent(
    msg_id: msg_id,
    chat_id: chat_id,
    msg_type: msg_type,
    from: from,
    text: text,
    reply_to_msgid: reply_to_msgid,
  ))
}

fn wechat_work_sender_decoder() -> decode.Decoder(WechatWorkSender) {
  use user_id <- decode.field("userid", decode.string)
  use name <- decode.field("name", decode.string)
  decode.success(WechatWorkSender(user_id: user_id, name: name))
}

fn wechat_work_text_decoder() -> decode.Decoder(WechatWorkText) {
  use content <- decode.field("content", decode.string)
  decode.success(WechatWorkText(content: content))
}

fn normalize_event(
  event: WechatWorkEvent,
) -> Result(port.ChannelMessage, port.ChannelError) {
  case event.msg_type {
    "text" ->
      case event.text {
        Some(text) ->
          case string.is_empty(text.content) {
            True -> Error(port.Ignored("empty content"))
            False ->
              Ok(port.ChannelMessage(
                id: event.msg_id,
                channel: "wechat_work",
                channel_id: event.chat_id,
                user_id: event.from.user_id,
                username: event.from.name,
                content: text.content,
                is_bot: False,
                reply_to_id: event.reply_to_msgid,
              ))
          }
        None -> Error(port.Ignored("empty content"))
      }
    other -> Error(port.Ignored("unsupported msgtype: " <> other))
  }
}

fn do_send(
  webhook_url: String,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  case build_reply_payload(reply) {
    Error(error) -> Error(error)
    Ok(payload) ->
      case request.to(webhook_url) {
        Error(_) -> Error(port.SendFailed("invalid webhook URL"))
        Ok(req) -> {
          let req =
            req
            |> request.set_method(http.Post)
            |> request.set_header("Content-Type", "application/json")
            |> request.set_body(payload)

          case hackney.send(req) {
            Ok(response) -> handle_wechat_work_response(response)
            Error(hackney.InvalidUtf8Response) ->
              Error(port.SendFailed("Invalid UTF-8 response from WeChat Work"))
            Error(hackney.Other(reason)) ->
              Error(port.SendFailed("HTTP error: " <> string.inspect(reason)))
          }
        }
      }
  }
}

fn handle_wechat_work_response(
  response: Response(String),
) -> Result(Nil, port.ChannelError) {
  case response.status {
    200 -> Ok(Nil)
    400 -> Error(port.SendFailed("Bad request - invalid payload"))
    401 | 403 -> Error(port.SendFailed("Unauthorized - check webhook URL"))
    429 -> Error(port.RateLimited(retry_after_seconds: 30))
    status ->
      Error(port.SendFailed("WeChat Work error: " <> int.to_string(status)))
  }
}
