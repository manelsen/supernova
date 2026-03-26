import gleam/option
import gleeunit/should
import supernova/adapters/google_chat_adapter
import supernova/channel/port

// ============================================================================
// Google Chat Adapter Tests — TDD Red Phase
// ============================================================================

// ---------------------------------------------------------------------------
// Event Parsing Tests
// ---------------------------------------------------------------------------

pub fn parse_message_event_test() {
  let event = google_chat_adapter.parse_event(sample_message_event())
  should.equal(event, Ok(port.ChannelMessage(
    id: "messages/abc123",
    channel: "google_chat",
    channel_id: "spaces/xyz789",
    user_id: "users/u123456",
    username: "",
    content: "Hello bot!",
    is_bot: False,
    reply_to_id: option.None,
  )))
}

pub fn parse_thread_reply_test() {
  let event = google_chat_adapter.parse_event(sample_thread_reply_event())
  should.equal(event, Ok(port.ChannelMessage(
    id: "messages/reply456",
    channel: "google_chat",
    channel_id: "spaces/xyz789",
    user_id: "users/u123456",
    username: "",
    content: "Reply in thread",
    is_bot: False,
    reply_to_id: option.Some("messages/parent123"),
  )))
}

pub fn parse_bot_message_ignored_test() {
  let event = google_chat_adapter.parse_event(sample_bot_message_event())
  should.equal(event, Error(port.Ignored("bot sender filtered")))
}

pub fn parse_empty_content_ignored_test() {
  let event = google_chat_adapter.parse_event(sample_empty_content_event())
  should.equal(event, Error(port.Ignored("empty content")))
}

pub fn parse_non_message_event_ignored_test() {
  // Google Chat sends CARD, ADDED_TO_SPACE, REMOVED_FROM_SPACE events
  let event = google_chat_adapter.parse_event(sample_card_event())
  should.equal(event, Error(port.Ignored("non-message event")))
}

pub fn parse_invalid_json_error_test() {
  // Invalid JSON that doesn't contain MESSAGE type
  let result = google_chat_adapter.parse_event("not json at all")
  should.equal(result, Error(port.Ignored("non-message event")))
}

// ---------------------------------------------------------------------------
// Reply Payload Tests
// ---------------------------------------------------------------------------

pub fn build_reply_payload_test() {
  let reply = port.ChannelReply(
    channel_id: "spaces/xyz789",
    content: "Hello back!",
    reply_to_id: option.None,
    interactive: option.None,
  )
  
  let result = google_chat_adapter.build_reply_payload(reply)
  should.be_ok(result)
}

pub fn build_thread_reply_payload_test() {
  let reply = port.ChannelReply(
    channel_id: "spaces/xyz789",
    content: "Thread reply",
    reply_to_id: option.Some("messages/parent123"),
    interactive: option.None,
  )
  
  let result = google_chat_adapter.build_reply_payload(reply)
  should.be_ok(result)
}

// ---------------------------------------------------------------------------
// Session Resolution Tests
// ---------------------------------------------------------------------------

pub fn session_id_test() {
  let msg = port.ChannelMessage(
    id: "messages/abc123",
    channel: "google_chat",
    channel_id: "spaces/xyz789",
    user_id: "users/u123456",
    username: "Test",
    content: "hi",
    is_bot: False,
    reply_to_id: option.None,
  )
  
  let session_id = google_chat_adapter.resolve_session_id(msg)
  should.equal(session_id, "google_chat:spaces/xyz789:users/u123456")
}

pub fn session_id_from_dm_test() {
  let msg = port.ChannelMessage(
    id: "messages/dm456",
    channel: "google_chat",
    channel_id: "spaces/dm001",
    user_id: "users/u789012",
    username: "DMUser",
    content: "dm",
    is_bot: False,
    reply_to_id: option.None,
  )
  
  let session_id = google_chat_adapter.resolve_session_id(msg)
  should.equal(session_id, "google_chat:spaces/dm001:users/u789012")
}

// ---------------------------------------------------------------------------
// Sample Event Fixtures
// ---------------------------------------------------------------------------

fn sample_message_event() -> String {
  // Compact JSON format (no spaces)
  "{\"type\":\"MESSAGE\",\"space\":{\"name\":\"spaces/xyz789\"},\"message\":{\"name\":\"messages/abc123\",\"text\":\"Hello bot!\",\"sender\":{\"name\":\"users/u123456\"}}}"
}

fn sample_thread_reply_event() -> String {
  // Thread reply with parent reference
  "{\"type\":\"MESSAGE\",\"space\":{\"name\":\"spaces/xyz789\"},\"message\":{\"name\":\"messages/reply456\",\"text\":\"Reply in thread\",\"sender\":{\"name\":\"users/u123456\"},\"thread\":{\"replyToMessage\":{\"name\":\"messages/parent123\"}}}}"
}

fn sample_bot_message_event() -> String {
  // Bot sender should be filtered
  "{\"type\":\"MESSAGE\",\"space\":{\"name\":\"spaces/xyz789\"},\"message\":{\"name\":\"messages/bot123\",\"text\":\"I'm a bot\",\"sender\":{\"name\":\"users/bot098\",\"type\":\"BOT\"}}}"
}

fn sample_empty_content_event() -> String {
  // Empty text should be ignored
  "{\"type\":\"MESSAGE\",\"space\":{\"name\":\"spaces/xyz789\"},\"message\":{\"name\":\"messages/empty123\",\"text\":\"\",\"sender\":{\"name\":\"users/u123456\"}}}"
}

fn sample_card_event() -> String {
  // Non-MESSAGE event type
  "{\"type\":\"CARD\",\"space\":{\"name\":\"spaces/xyz789\"},\"message\":{\"name\":\"messages/card123\",\"sender\":{\"name\":\"users/u123456\"}}}"
}
