import gleam/option
import gleeunit/should
import supernova/adapters/mattermost_adapter
import supernova/channel/port

// ============================================================================
// Mattermost Adapter Tests — TDD Red Phase
// ============================================================================

// ---------------------------------------------------------------------------
// Event Parsing Tests
// ---------------------------------------------------------------------------

pub fn parse_text_message_test() {
  let event = mattermost_adapter.parse_event(sample_text_event())
  should.equal(
    event,
    Ok(port.ChannelMessage(
      id: "abc123",
      channel: "mattermost",
      channel_id: "channel-001",
      user_id: "user-001",
      username: "",
      content: "Hello from Mattermost",
      is_bot: False,
      reply_to_id: option.None,
    )),
  )
}

pub fn parse_reply_message_test() {
  let event = mattermost_adapter.parse_event(sample_reply_event())
  should.equal(
    event,
    Ok(port.ChannelMessage(
      id: "reply-456",
      channel: "mattermost",
      channel_id: "channel-001",
      user_id: "user-002",
      username: "",
      content: "This is a reply",
      is_bot: False,
      reply_to_id: option.Some("root-789"),
    )),
  )
}

pub fn parse_reply_with_parent_id_test() {
  let event = mattermost_adapter.parse_event(sample_reply_with_parent_event())
  should.equal(
    event,
    Ok(port.ChannelMessage(
      id: "reply-999",
      channel: "mattermost",
      channel_id: "channel-002",
      user_id: "user-003",
      username: "",
      content: "Reply using parent_id",
      is_bot: False,
      reply_to_id: option.Some("parent-111"),
    )),
  )
}

pub fn parse_bot_message_ignored_test() {
  let event = mattermost_adapter.parse_event(sample_bot_event())
  should.equal(event, Error(port.Ignored("bot sender filtered")))
}

pub fn parse_empty_content_ignored_test() {
  let event = mattermost_adapter.parse_event(sample_empty_event())
  should.equal(event, Error(port.Ignored("empty content")))
}

pub fn parse_invalid_json_error_test() {
  let result = mattermost_adapter.parse_event("{\"not\": \"valid\"}")
  should.equal(result, Error(port.SendFailed("invalid JSON")))
}

pub fn start_returns_adapter_test() {
  let assert Ok(adapter) =
    mattermost_adapter.start(
      "mattermost-token",
      "https://mattermost.example.com",
      fn(_, _) { Error(port.Ignored("unused")) },
    )

  adapter.name |> should.equal("mattermost")
}

// ---------------------------------------------------------------------------
// Message Building Tests
// ---------------------------------------------------------------------------

pub fn build_reply_payload_test() {
  let reply =
    port.ChannelReply(
      channel_id: "channel-001",
      content: "Hello back!",
      reply_to_id: option.None,
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [],
    )

  let result = mattermost_adapter.build_reply_payload(reply)
  should.equal(
    result,
    Ok("{\"channel_id\":\"channel-001\",\"message\":\"Hello back!\"}"),
  )
}

pub fn build_thread_reply_payload_test() {
  let reply =
    port.ChannelReply(
      channel_id: "channel-001",
      content: "Thread reply",
      reply_to_id: option.Some("root-789"),
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [],
    )

  let result = mattermost_adapter.build_reply_payload(reply)
  should.equal(
    result,
    Ok(
      "{\"channel_id\":\"channel-001\",\"message\":\"Thread reply\",\"root_id\":\"root-789\"}",
    ),
  )
}

// ---------------------------------------------------------------------------
// Session Resolution Tests
// ---------------------------------------------------------------------------

pub fn session_id_test() {
  let msg =
    port.ChannelMessage(
      id: "msg-123",
      channel: "mattermost",
      channel_id: "channel-001",
      user_id: "user-001",
      username: "TestUser",
      content: "hi",
      is_bot: False,
      reply_to_id: option.None,
    )

  let session_id = mattermost_adapter.resolve_session_id(msg)
  should.equal(session_id, "mattermost:channel-001:user-001")
}

// ---------------------------------------------------------------------------
// Sample Event Fixtures
// ---------------------------------------------------------------------------

fn sample_text_event() -> String {
  "{\"id\": \"abc123\", \"channel_id\": \"channel-001\", \"user_id\": \"user-001\", \"message\": \"Hello from Mattermost\", \"create_at\": 1234567890}"
}

fn sample_reply_event() -> String {
  "{\"id\": \"reply-456\", \"channel_id\": \"channel-001\", \"user_id\": \"user-002\", \"message\": \"This is a reply\", \"create_at\": 1234567891, \"root_id\": \"root-789\"}"
}

fn sample_reply_with_parent_event() -> String {
  "{\"id\": \"reply-999\", \"channel_id\": \"channel-002\", \"user_id\": \"user-003\", \"message\": \"Reply using parent_id\", \"create_at\": 1234567892, \"parent_id\": \"parent-111\"}"
}

fn sample_bot_event() -> String {
  "{\"id\": \"bot-msg-001\", \"channel_id\": \"channel-001\", \"user_id\": \"bot-user-001\", \"message\": \"I'm a bot\", \"create_at\": 1234567893, \"is_bot\": true}"
}

fn sample_empty_event() -> String {
  "{\"id\": \"empty-msg-001\", \"channel_id\": \"channel-001\", \"user_id\": \"user-001\", \"message\": \"\", \"create_at\": 1234567894}"
}
