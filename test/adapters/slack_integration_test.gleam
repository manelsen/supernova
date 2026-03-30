import gleam/option.{None, Some}
import gleeunit/should
import supernova/adapters/slack_adapter
import supernova/channel/port

// ============================================================================
// Slack Router Integration Tests — Verify adapter connects to router
// ============================================================================

// Test: parse_event returns proper ChannelMessage format that router expects
pub fn adapter_produces_router_compatible_message_test() {
  let event_json = sample_mention_event()

  // Adapter parses the event
  let parse_result = slack_adapter.parse_event(event_json)

  case parse_result {
    Ok(msg) -> {
      // Verify the message has all fields the router needs
      should.equal(msg.channel, "slack")
      should.equal(msg.user_id, "U012345678")
      should.equal(msg.is_bot, False)
      should.not_equal(msg.content, "")
    }
    Error(_) -> should.equal(True, False)
    // Expected Ok
  }
}

// Test: adapter respects bot filtering (what router expects)
pub fn adapter_filters_bots_like_router_expects_test() {
  let bot_event = sample_bot_message_event()

  let parse_result = slack_adapter.parse_event(bot_event)

  // Router expects bot messages to be filtered with Ignored error
  case parse_result {
    Ok(_) -> should.equal(True, False)
    // Expected Error
    Error(port.Ignored(reason)) -> should.equal(reason, "bot sender filtered")
    Error(_) -> should.equal(True, False)
    // Expected Ignored specifically
  }
}

// Test: adapter session resolution format
pub fn adapter_session_id_format_matches_router_test() {
  let msg =
    port.ChannelMessage(
      id: "123",
      channel: "slack",
      channel_id: "C012345678",
      user_id: "U012345678",
      username: "Test",
      content: "hi",
      is_bot: False,
      reply_to_id: None,
    )

  let session_id = slack_adapter.resolve_session_id(msg)

  // Router uses this format internally
  should.equal(session_id, "slack:C012345678:U012345678")
}

// Test: adapter produces Threading-compatible reply_to_id
pub fn adapter_extracts_thread_ts_like_router_expects_test() {
  let event_json = sample_thread_event()

  let parse_result = slack_adapter.parse_event(event_json)

  case parse_result {
    Ok(msg) -> {
      // Router needs reply_to_id for threading
      case msg.reply_to_id {
        Some(id) -> should.equal(id, "1234567890.111111")
        None -> should.equal(True, False)
        // Expected Some
      }
    }
    Error(_) -> should.equal(True, False)
    // Expected Ok
  }
}

// ============================================================================
// Fixtures
// ============================================================================

fn sample_mention_event() -> String {
  "{\"type\": \"app_mention\", \"user\": \"U012345678\", \"text\": \"<@U012345678> Hello bot!\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.123456\", \"event_ts\": \"1234567890.123456\"}"
}

fn sample_bot_message_event() -> String {
  "{\"type\": \"message\", \"user\": \"B012345678\", \"text\": \"I'm a bot\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.777777\", \"bot_id\": \"B012345678\"}"
}

fn sample_thread_event() -> String {
  "{\"type\": \"message\", \"user\": \"U012345678\", \"text\": \"Reply in thread\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.999999\", \"thread_ts\": \"1234567890.111111\"}"
}
