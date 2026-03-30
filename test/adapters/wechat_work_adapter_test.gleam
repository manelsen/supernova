import gleam/option
import gleeunit/should
import supernova/adapters/wechat_work_adapter
import supernova/channel/port

pub fn parse_text_message_test() {
  let event = wechat_work_adapter.parse_event(sample_text_event())
  should.equal(
    event,
    Ok(port.ChannelMessage(
      id: "msg-001",
      channel: "wechat_work",
      channel_id: "chat-001",
      user_id: "zhangsan",
      username: "Alice",
      content: "Hello from WeChat Work",
      is_bot: False,
      reply_to_id: option.None,
    )),
  )
}

pub fn parse_thread_reply_test() {
  let event = wechat_work_adapter.parse_event(sample_thread_reply_event())
  should.equal(
    event,
    Ok(port.ChannelMessage(
      id: "msg-002",
      channel: "wechat_work",
      channel_id: "chat-001",
      user_id: "lisi",
      username: "Bob",
      content: "Reply in thread",
      is_bot: False,
      reply_to_id: option.Some("msg-parent"),
    )),
  )
}

pub fn parse_non_text_event_ignored_test() {
  let event = wechat_work_adapter.parse_event(sample_image_event())
  should.equal(event, Error(port.Ignored("unsupported msgtype: image")))
}

pub fn parse_invalid_json_error_test() {
  let event = wechat_work_adapter.parse_event("not json")
  should.equal(event, Error(port.SendFailed("invalid JSON")))
}

pub fn start_returns_adapter_test() {
  let assert Ok(adapter) =
    wechat_work_adapter.start(
      "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test",
      fn(_, _) { Error(port.Ignored("unused")) },
    )

  adapter.name |> should.equal("wechat_work")
}

pub fn build_reply_payload_test() {
  let reply =
    port.ChannelReply(
      channel_id: "chat-001",
      content: "Hello back!",
      reply_to_id: option.None,
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [],
    )

  let result = wechat_work_adapter.build_reply_payload(reply)
  should.equal(
    result,
    Ok("{\"msgtype\":\"text\",\"text\":{\"content\":\"Hello back!\"}}"),
  )
}

pub fn session_id_test() {
  let msg =
    port.ChannelMessage(
      id: "msg-123",
      channel: "wechat_work",
      channel_id: "chat-001",
      user_id: "zhangsan",
      username: "Alice",
      content: "hi",
      is_bot: False,
      reply_to_id: option.None,
    )

  let session_id = wechat_work_adapter.resolve_session_id(msg)
  should.equal(session_id, "wechat_work:chat-001:zhangsan")
}

fn sample_text_event() -> String {
  "{\"msgid\":\"msg-001\",\"chatid\":\"chat-001\",\"msgtype\":\"text\",\"text\":{\"content\":\"Hello from WeChat Work\"},\"from\":{\"userid\":\"zhangsan\",\"name\":\"Alice\"}}"
}

fn sample_thread_reply_event() -> String {
  "{\"msgid\":\"msg-002\",\"chatid\":\"chat-001\",\"msgtype\":\"text\",\"text\":{\"content\":\"Reply in thread\"},\"reply_to_msgid\":\"msg-parent\",\"from\":{\"userid\":\"lisi\",\"name\":\"Bob\"}}"
}

fn sample_image_event() -> String {
  "{\"msgid\":\"msg-003\",\"chatid\":\"chat-001\",\"msgtype\":\"image\",\"from\":{\"userid\":\"zhangsan\",\"name\":\"Alice\"}}"
}
