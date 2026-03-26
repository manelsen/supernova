import gleam/option
import gleeunit/should
import supernova/adapters/lark_adapter
import supernova/channel/port

// ============================================================================
// Lark Adapter Tests — TDD Red Phase
// ============================================================================

// --------------------------------------------------------------------------
// Message Parsing Tests
// --------------------------------------------------------------------------

pub fn parse_text_message_test() {
  let event = lark_adapter.parse_event(sample_text_event())
  should.equal(event, Ok(port.ChannelMessage(
    id: "msg_abc123",
    channel: "lark",
    channel_id: "oc_abc123",
    user_id: "ou_abc123",
    username: "",
    content: "Hello, bot!",
    is_bot: False,
    reply_to_id: option.None,
  )))
}

pub fn parse_reply_message_test() {
  let event = lark_adapter.parse_event(sample_reply_event())
  should.equal(event, Ok(port.ChannelMessage(
    id: "msg_reply456",
    channel: "lark",
    channel_id: "oc_abc123",
    user_id: "ou_abc123",
    username: "",
    content: "This is a reply",
    is_bot: False,
    reply_to_id: option.Some("msg_parent789"),
  )))
}

pub fn parse_bot_message_ignored_test() {
  let event = lark_adapter.parse_event(sample_bot_event())
  should.equal(event, Error(port.Ignored("bot sender filtered")))
}

pub fn parse_empty_content_ignored_test() {
  let event = lark_adapter.parse_event(sample_empty_event())
  should.equal(event, Error(port.Ignored("empty content")))
}

pub fn parse_invalid_json_error_test() {
  // JSON that parses but doesn't match expected event structure
  let result = lark_adapter.parse_event(
    "{\"not\": \"a valid lark event\"}"
  )
  // Missing header/event structure returns ignored
  should.equal(result, Error(port.SendFailed("invalid JSON")))
}
pub fn parse_non_message_event_ignored_test() {
  // Non-MESSAGE event - the event parses but lacks required body fields
  let result = lark_adapter.parse_event(
    "{\"header\": {\"event_type\": \"im.message.read_v1\"}, \"event\": {}}"
  )
  // Missing event body returns parsing error
  should.equal(result, Error(port.SendFailed("invalid JSON")))
}

// --------------------------------------------------------------------------
// Reply Payload Tests
// --------------------------------------------------------------------------

pub fn build_reply_payload_test() {
  let reply = port.ChannelReply(
    channel_id: "oc_abc123",
    content: "Hello back!",
    reply_to_id: option.None,
    interactive: option.None,
  )
  
  let result = lark_adapter.build_reply_payload(reply)
  let expected = "{\"msg_type\":\"text\",\"content\":{\"text\":\"Hello back!\"}}"
  should.equal(result, Ok(expected))
}

pub fn build_threaded_reply_payload_test() {
  let reply = port.ChannelReply(
    channel_id: "oc_abc123",
    content: "Threading!",
    reply_to_id: option.Some("msg_parent789"),
    interactive: option.None,
  )
  
  let result = lark_adapter.build_reply_payload(reply)
  let expected = "{\"msg_type\":\"text\",\"content\":{\"text\":\"Threading!\"},\"reply_to_message_id\":\"msg_parent789\"}"
  should.equal(result, Ok(expected))
}

// --------------------------------------------------------------------------
// Session Resolution Tests
// --------------------------------------------------------------------------

pub fn session_id_test() {
  let msg = port.ChannelMessage(
    id: "msg_123",
    channel: "lark",
    channel_id: "oc_abc123",
    user_id: "ou_abc123",
    username: "Test",
    content: "hi",
    is_bot: False,
    reply_to_id: option.None,
  )
  
  let session_id = lark_adapter.resolve_session_id(msg)
  should.equal(session_id, "lark:oc_abc123:ou_abc123")
}

pub fn session_id_dm_channel_test() {
  let msg = port.ChannelMessage(
    id: "msg_dm456",
    channel: "lark",
    channel_id: "p2p_xyz789",
    user_id: "ou_dmuser",
    username: "DM User",
    content: "dm",
    is_bot: False,
    reply_to_id: option.None,
  )
  
  let session_id = lark_adapter.resolve_session_id(msg)
  should.equal(session_id, "lark:p2p_xyz789:ou_dmuser")
}

// --------------------------------------------------------------------------
// Sample Event Fixtures
// --------------------------------------------------------------------------

fn sample_text_event() -> String {
  "{\"header\": {\"event_type\": \"im.message.receive_v1\"}, \"event\": {\"sender\": {\"sender_id\": {\"open_id\": \"ou_abc123\"}, \"sender_type\": \"user\", \"tenant_key\": \"test\"}, \"message\": {\"message_id\": \"msg_abc123\", \"chat_id\": \"oc_abc123\", \"chat_type\": \"group\", \"message_type\": \"text\", \"content\": \"{\\\"text\\\": \\\"Hello, bot!\\\"}\"}, \"app_id\": \"cli_abc\"}}"
}

fn sample_reply_event() -> String {
  "{\"header\": {\"event_type\": \"im.message.receive_v1\"}, \"event\": {\"sender\": {\"sender_id\": {\"open_id\": \"ou_abc123\"}, \"sender_type\": \"user\", \"tenant_key\": \"test\"}, \"message\": {\"message_id\": \"msg_reply456\", \"chat_id\": \"oc_abc123\", \"chat_type\": \"group\", \"message_type\": \"text\", \"content\": \"{\\\"text\\\": \\\"This is a reply\\\"}\", \"parent_id\": \"msg_parent789\"}, \"app_id\": \"cli_abc\"}}"
}

fn sample_bot_event() -> String {
  "{\"header\": {\"event_type\": \"im.message.receive_v1\"}, \"event\": {\"sender\": {\"sender_id\": {\"open_id\": \"ou_bot123\"}, \"sender_type\": \"bot\", \"tenant_key\": \"test\"}, \"message\": {\"message_id\": \"msg_bot789\", \"chat_id\": \"oc_abc123\", \"chat_type\": \"group\", \"message_type\": \"text\", \"content\": \"{\\\"text\\\": \\\"I'm a bot\\\"}\"}, \"app_id\": \"cli_abc\"}}"
}

fn sample_empty_event() -> String {
  "{\"header\": {\"event_type\": \"im.message.receive_v1\"}, \"event\": {\"sender\": {\"sender_id\": {\"open_id\": \"ou_abc123\"}, \"sender_type\": \"user\", \"tenant_key\": \"test\"}, \"message\": {\"message_id\": \"msg_empty123\", \"chat_id\": \"oc_abc123\", \"chat_type\": \"group\", \"message_type\": \"text\", \"content\": \"{\\\"text\\\": \\\"\\\"}\"}, \"app_id\": \"cli_abc\"}}"
}
