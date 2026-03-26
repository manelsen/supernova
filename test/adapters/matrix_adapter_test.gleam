import gleam/option
import gleam/string
import gleeunit/should
import supernova/adapters/matrix_adapter
import supernova/channel/port

// ============================================================================
// Matrix Adapter Tests — TDD Red Phase
// ============================================================================

// Test bot detection directly via public function
pub fn is_bot_detection_test() {
  // Test is_bot_sender directly with known bot sender
  let is_bot = matrix_adapter.is_bot_sender("@bot:matrix.example.org")
  should.equal(is_bot, True)
}


// --------------------------------------------------------------------------
// Message Parsing Tests
// --------------------------------------------------------------------------

pub fn parse_text_message_test() {
  let event = matrix_adapter.parse_event(sample_text_event())
  should.equal(event, Ok(port.ChannelMessage(
    id: "$event_id:matrix.example.org",
    channel: "matrix",
    channel_id: "!room_id:matrix.example.org",
    user_id: "@user:matrix.example.org",
    username: "UserDisplay",
    content: "Hello, bot!",
    is_bot: False,
    reply_to_id: option.None,
  )))
}

pub fn parse_html_message_test() {
  let event = matrix_adapter.parse_event(sample_html_event())
  // HTML should be stripped, keeping plain text
  should.equal(event, Ok(port.ChannelMessage(
    id: "$event_id2:matrix.example.org",
    channel: "matrix",
    channel_id: "!room_id:matrix.example.org",
    user_id: "@user:matrix.example.org",
    username: "UserDisplay",
    content: "Bold message",
    is_bot: False,
    reply_to_id: option.None,
  )))
}

pub fn parse_reply_message_test() {
  let event = matrix_adapter.parse_event(sample_reply_event())
  should.equal(event, Ok(port.ChannelMessage(
    id: "$reply_event:matrix.example.org",
    channel: "matrix",
    channel_id: "!room_id:matrix.example.org",
    user_id: "@user:matrix.example.org",
    username: "UserDisplay",
    content: "This is a reply",
    is_bot: False,
    reply_to_id: option.Some("$parent_event:matrix.example.org"),
  )))
}

pub fn parse_bot_message_ignored_test() {
  let event = matrix_adapter.parse_event(sample_bot_event())
  should.equal(event, Error(port.Ignored("bot sender filtered")))
}

pub fn parse_empty_content_ignored_test() {
  let event = matrix_adapter.parse_event(sample_empty_event())
  should.equal(event, Error(port.Ignored("empty content")))
}

pub fn parse_invalid_json_error_test() {
  let result = matrix_adapter.parse_event(
    "{\"not\": \"a valid matrix event\"}"
  )
  should.equal(result, Error(port.SendFailed("invalid JSON")))
}

// --------------------------------------------------------------------------
// Message Sending Tests  
// --------------------------------------------------------------------------

pub fn send_text_reply_test() {
  let reply = port.ChannelReply(
    channel_id: "!room_id:matrix.example.org",
    content: "Hello back!",
    reply_to_id: option.None,
    interactive: option.None,
  )
  
  let result = matrix_adapter.build_send_payload(reply)
  let expected = "{\"msgtype\":\"m.text\",\"body\":\"Hello back!\"}"
  should.equal(result, Ok(expected))
}

pub fn send_threaded_reply_test() {
  let reply = port.ChannelReply(
    channel_id: "!room_id:matrix.example.org",
    content: "Threading!",
    reply_to_id: option.Some("$parent:matrix.example.org"),
    interactive: option.None,
  )
  
  let result = matrix_adapter.build_send_payload(reply)
  // Matrix uses m.relates_to for threading
  let expected = "{\"msgtype\":\"m.text\",\"body\":\"Threading!\",\"m.relates_to\":{\"rel_type\":\"m.thread\",\"event_id\":\"$parent:matrix.example.org\"}}"
  should.equal(result, Ok(expected))
}

pub fn send_to_dm_channel_test() {
  let reply = port.ChannelReply(
    channel_id: "!dm_room:matrix.example.org",
    content: "DM reply",
    reply_to_id: option.None,
    interactive: option.None,
  )
  
  let result = matrix_adapter.build_send_payload(reply)
  // DM rooms should be handled correctly (Result -> should be Ok)
  should.be_ok(result)
}

// --------------------------------------------------------------------------
// Session Resolution Tests
// --------------------------------------------------------------------------

pub fn session_id_from_room_id_test() {
  let msg = port.ChannelMessage(
    id: "123",
    channel: "matrix",
    channel_id: "!abc:matrix.org",
    user_id: "@user:matrix.org",
    username: "Test",
    content: "hi",
    is_bot: False,
    reply_to_id: option.None,
  )
  
  let session_id = matrix_adapter.resolve_session_id(msg)
  should.equal(session_id, "matrix:!abc:matrix.org:@user:matrix.org")
}

pub fn session_id_dm_channel_test() {
  let msg = port.ChannelMessage(
    id: "456",
    channel: "matrix",
    channel_id: "!dm_xyz:matrix.org",
    user_id: "@other:matrix.org",
    username: "Other",
    content: "dm",
    is_bot: False,
    reply_to_id: option.None,
  )
  
  let session_id = matrix_adapter.resolve_session_id(msg)
  // DM rooms have unique identifiers
  should.equal(session_id, "matrix:!dm_xyz:matrix.org:@other:matrix.org")
}

// --------------------------------------------------------------------------
// Sample Event Fixtures
// --------------------------------------------------------------------------

fn sample_text_event() -> String {
  "{\"type\": \"m.room.message\", \"sender\": \"@user:matrix.example.org\", \"room_id\": \"!room_id:matrix.example.org\", \"event_id\": \"$event_id:matrix.example.org\", \"origin_server_ts\": 1234567890, \"content\": {\"msgtype\": \"m.text\", \"body\": \"Hello, bot!\"}, \"unsigned\": {\"displayname\": \"UserDisplay\"}}"
}

fn sample_html_event() -> String {
  "{\"type\": \"m.room.message\", \"sender\": \"@user:matrix.example.org\", \"room_id\": \"!room_id:matrix.example.org\", \"event_id\": \"$event_id2:matrix.example.org\", \"origin_server_ts\": 1234567890, \"content\": {\"msgtype\": \"m.text\", \"body\": \"Bold message\", \"format\": \"org.matrix.custom.html\", \"formatted_body\": \"<strong>Bold message</strong>\"}, \"unsigned\": {\"displayname\": \"UserDisplay\"}}"
}

fn sample_reply_event() -> String {
  "{\"type\": \"m.room.message\", \"sender\": \"@user:matrix.example.org\", \"room_id\": \"!room_id:matrix.example.org\", \"event_id\": \"$reply_event:matrix.example.org\", \"origin_server_ts\": 1234567890, \"content\": {\"msgtype\": \"m.text\", \"body\": \"This is a reply\"}, \"unsigned\": {\"displayname\": \"UserDisplay\"}, \"m.relates_to\": {\"rel_type\": \"m.thread\", \"event_id\": \"$parent_event:matrix.example.org\"}}"
}

fn sample_bot_event() -> String {
  "{\"type\": \"m.room.message\", \"sender\": \"@bot:matrix.example.org\", \"room_id\": \"!room_id:matrix.example.org\", \"event_id\": \"$bot_event:matrix.example.org\", \"origin_server_ts\": 1234567890, \"content\": {\"msgtype\": \"m.text\", \"body\": \"I'm a bot\"}, \"unsigned\": {\"displayname\": \"BotName\"}}"
}

fn sample_empty_event() -> String {
  "{\"type\": \"m.room.message\", \"sender\": \"@user:matrix.example.org\", \"room_id\": \"!room_id:matrix.example.org\", \"event_id\": \"$empty_event:matrix.example.org\", \"origin_server_ts\": 1234567890, \"content\": {\"msgtype\": \"m.text\", \"body\": \"\"}, \"unsigned\": {\"displayname\": \"UserDisplay\"}}"
}
