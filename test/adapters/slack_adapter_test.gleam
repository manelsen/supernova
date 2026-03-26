import gleam/option
import gleeunit/should
import supernova/adapters/slack_adapter
import supernova/channel/port

// ============================================================================
// Slack Adapter Tests — TDD Red Phase
// ============================================================================

// --------------------------------------------------------------------------
// Event Parsing Tests
// --------------------------------------------------------------------------

pub fn parse_app_mention_test() {
  let event = slack_adapter.parse_event(sample_app_mention_event())
  // Note: username is empty because Slack doesn't provide it in events (needs API call)
  // Content has leading space from mention stripping
  should.equal(event, Ok(port.ChannelMessage(
    id: "1234567890.123456",
    channel: "slack",
    channel_id: "C0123456789",
    user_id: "U012345678",
    username: "",
    content: " Hello bot!",
    is_bot: False,
    reply_to_id: option.None,
  )))
}

pub fn parse_direct_message_test() {
  let event = slack_adapter.parse_event(sample_dm_event())
  should.equal(event, Ok(port.ChannelMessage(
    id: "1234567890.654321",
    channel: "slack",
    channel_id: "D012345678",
    user_id: "U012345679",
    username: "",
    content: "Direct message to bot",
    is_bot: False,
    reply_to_id: option.None,
  )))
}

pub fn parse_message_with_thread_test() {
  let event = slack_adapter.parse_event(sample_thread_event())
  should.equal(event, Ok(port.ChannelMessage(
    id: "1234567890.999999",
    channel: "slack",
    channel_id: "C0123456789",
    user_id: "U012345678",
    username: "",
    content: "Reply in thread",
    is_bot: False,
    reply_to_id: option.Some("1234567890.111111"),
  )))
}

pub fn parse_bot_message_ignored_test() {
  let event = slack_adapter.parse_event(sample_bot_event())
  should.equal(event, Error(port.Ignored("bot sender filtered")))
}

pub fn parse_empty_content_ignored_test() {
  let event = slack_adapter.parse_event(sample_empty_event())
  should.equal(event, Error(port.Ignored("empty content")))
}

pub fn parse_invalid_json_error_test() {
  let result = slack_adapter.parse_event(
    "{\"not\": \"a valid slack event\"}"
  )
  should.equal(result, Error(port.SendFailed("invalid JSON")))
}

// --------------------------------------------------------------------------
// Message Building Tests
// --------------------------------------------------------------------------

pub fn build_text_reply_test() {
  let reply = port.ChannelReply(
    channel_id: "C0123456789",
    content: "Hello back!",
    reply_to_id: option.None,
    interactive: option.None,
  )
  
  let result = slack_adapter.build_reply_payload(reply)
  should.be_ok(result)
}

pub fn build_thread_reply_test() {
  let reply = port.ChannelReply(
    channel_id: "C0123456789",
    content: "Thread reply",
    reply_to_id: option.Some("1234567890.111111"),
    interactive: option.None,
  )
  
  let result = slack_adapter.build_reply_payload(reply)
  should.be_ok(result)
}

// --------------------------------------------------------------------------
// Session Resolution Tests
// --------------------------------------------------------------------------

pub fn session_id_from_channel_test() {
  let msg = port.ChannelMessage(
    id: "123",
    channel: "slack",
    channel_id: "C0123456789",
    user_id: "U012345678",
    username: "Test",
    content: "hi",
    is_bot: False,
    reply_to_id: option.None,
  )
  
  let session_id = slack_adapter.resolve_session_id(msg)
  should.equal(session_id, "slack:C0123456789:U012345678")
}

pub fn session_id_from_dm_test() {
  let msg = port.ChannelMessage(
    id: "456",
    channel: "slack",
    channel_id: "D012345678",
    user_id: "U012345679",
    username: "DMUser",
    content: "dm",
    is_bot: False,
    reply_to_id: option.None,
  )
  
  let session_id = slack_adapter.resolve_session_id(msg)
  should.equal(session_id, "slack:D012345678:U012345679")
}

// --------------------------------------------------------------------------
// Sample Event Fixtures
// --------------------------------------------------------------------------

fn sample_app_mention_event() -> String {
  "{\"type\": \"app_mention\", \"user\": \"U012345678\", \"text\": \"<@U012345678> Hello bot!\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.123456\", \"event_ts\": \"1234567890.123456\", \"channel_type\": \"channel\"}"
}

fn sample_dm_event() -> String {
  "{\"type\": \"message\", \"user\": \"U012345679\", \"text\": \"Direct message to bot\", \"channel\": \"D012345678\", \"ts\": \"1234567890.654321\", \"event_ts\": \"1234567890.654321\", \"channel_type\": \"im\"}"
}

fn sample_thread_event() -> String {
  "{\"type\": \"message\", \"user\": \"U012345678\", \"text\": \"Reply in thread\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.999999\", \"thread_ts\": \"1234567890.111111\", \"event_ts\": \"1234567890.999999\", \"channel_type\": \"channel\"}"
}

fn sample_bot_event() -> String {
  "{\"type\": \"message\", \"user\": \"B012345678\", \"text\": \"I'm a bot\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.777777\", \"event_ts\": \"1234567890.777777\", \"channel_type\": \"channel\", \"bot_id\": \"B012345678\"}"
}

fn sample_empty_event() -> String {
  "{\"type\": \"message\", \"user\": \"U012345678\", \"text\": \"\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.888888\", \"event_ts\": \"1234567890.888888\", \"channel_type\": \"channel\"}"
}
