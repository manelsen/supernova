import gleam/option.{None, Some}
import gleeunit/should
import gleam/result
import supernova/adapters/matrix_adapter
import supernova/channel/port

// ============================================================================
// Matrix Router Integration Tests — Verify adapter connects to router
// ============================================================================

// Test: parse_event returns proper ChannelMessage format that router expects
pub fn adapter_produces_router_compatible_message_test() {
  let event_json = sample_user_message_event()
  
  // Adapter parses the event
  let parse_result = matrix_adapter.parse_event(event_json)
  
  case parse_result {
    Ok(msg) -> {
      // Verify the message has all fields the router needs
      should.equal(msg.channel, "matrix")
      should.equal(msg.user_id, "@user:matrix.example.org")
      should.equal(msg.is_bot, False)
      should.not_equal(msg.content, "")
    }
    Error(_) -> should.equal(True, False)  // Expected Ok
  }
}

// Test: adapter respects bot filtering (what router expects)
pub fn adapter_filters_bots_like_router_expects_test() {
  let bot_event = sample_bot_message_event()
  
  let parse_result = matrix_adapter.parse_event(bot_event)
  
  // Router expects bot messages to be filtered with Ignored error
  case parse_result {
    Ok(_) -> should.equal(True, False)  // Expected Error
    Error(port.Ignored(reason)) -> should.equal(reason, "bot sender filtered")
    Error(_) -> should.equal(True, False)  // Expected Ignored specifically
  }
}

// Test: adapter session resolution format
pub fn adapter_session_id_format_matches_router_test() {
  let msg = port.ChannelMessage(
    id: "123",
    channel: "matrix",
    channel_id: "!room:matrix.org",
    user_id: "@user:matrix.org",
    username: "Test",
    content: "hi",
    is_bot: False,
    reply_to_id: None,
  )
  
  let session_id = matrix_adapter.resolve_session_id(msg)
  
  // Router uses this format internally
  should.equal(session_id, "matrix:!room:matrix.org:@user:matrix.org")
}

// Test: adapter produces Threading-compatible reply_to_id
pub fn adapter_extracts_thread_id_like_router_expects_test() {
  let event_json = sample_thread_reply_event()
  
  let parse_result = matrix_adapter.parse_event(event_json)
  
  case parse_result {
    Ok(msg) -> {
      // Router needs reply_to_id for threading
      case msg.reply_to_id {
        Some(id) -> should.equal(id, "$parent:matrix.example.org")
        None -> should.equal(True, False)  // Expected Some
      }
    }
    Error(_) -> should.equal(True, False)  // Expected Ok
  }
}

// ============================================================================
// Fixtures
// ============================================================================

fn sample_user_message_event() -> String {
  "{\"type\": \"m.room.message\", \"sender\": \"@user:matrix.example.org\", \"room_id\": \"!room:matrix.example.org\", \"event_id\": \"$event:matrix.example.org\", \"content\": {\"msgtype\": \"m.text\", \"body\": \"Hello!\"}, \"unsigned\": {\"displayname\": \"UserName\"}}"
}

fn sample_bot_message_event() -> String {
  "{\"type\": \"m.room.message\", \"sender\": \"@bot:matrix.example.org\", \"room_id\": \"!room:matrix.example.org\", \"event_id\": \"$bot:matrix.example.org\", \"content\": {\"msgtype\": \"m.text\", \"body\": \"I'm a bot\"}}"
}

fn sample_thread_reply_event() -> String {
  "{\"type\": \"m.room.message\", \"sender\": \"@user:matrix.example.org\", \"room_id\": \"!room:matrix.example.org\", \"event_id\": \"$reply:matrix.example.org\", \"content\": {\"msgtype\": \"m.text\", \"body\": \"Reply\"}, \"m.relates_to\": {\"rel_type\": \"m.thread\", \"event_id\": \"$parent:matrix.example.org\"}}"
}
