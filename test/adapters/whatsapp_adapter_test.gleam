import gleam/option
import gleeunit/should
import supernova/adapters/whatsapp_adapter
import supernova/channel/port

// ============================================================================
// WhatsApp Adapter Tests — TDD Red Phase
// ============================================================================

// --------------------------------------------------------------------------
// Event Parsing Tests
// --------------------------------------------------------------------------

pub fn parse_text_message_test() {
  let event = whatsapp_adapter.parse_event(sample_text_message())
  should.equal(event, Ok(port.ChannelMessage(
    id: "wamid.1234567890",
    channel: "whatsapp",
    channel_id: "123456789",
    user_id: "15551234567",
    username: "",
    content: "Hello, bot!",
    is_bot: False,
    reply_to_id: option.None,
  )))
}

pub fn parse_media_message_test() {
  // Media message with caption
  let event = whatsapp_adapter.parse_event(sample_image_message())
  should.equal(event, Ok(port.ChannelMessage(
    id: "wamid.9876543210",
    channel: "whatsapp",
    channel_id: "123456789",
    user_id: "15551234567",
    username: "",
    content: "Check this image!",
    is_bot: False,
    reply_to_id: option.None,
  )))
}

pub fn parse_media_message_no_caption_test() {
  // Media messages without caption should be filtered as empty content
  let event = whatsapp_adapter.parse_event(sample_audio_message())
  should.equal(event, Error(port.Ignored("empty content")))
}

pub fn parse_bot_message_ignored_test() {
  // Message from the bot's own phone number should be ignored
  let event = whatsapp_adapter.parse_event(sample_bot_message())
  should.equal(event, Error(port.Ignored("bot sender filtered")))
}

pub fn parse_empty_content_ignored_test() {
  // Text message with empty body
  let event = whatsapp_adapter.parse_event(sample_empty_text_message())
  should.equal(event, Error(port.Ignored("empty content")))
}

pub fn parse_non_message_entry_ignored_test() {
  // Non-message entry (status updates) - type is "delivered"
  let event = whatsapp_adapter.parse_event(sample_status_update())
  should.equal(event, Error(port.Ignored("unsupported message type: delivered")))
}

pub fn parse_reply_message_test() {
  // Message with reply context
  let event = whatsapp_adapter.parse_event(sample_reply_message())
  should.equal(event, Ok(port.ChannelMessage(
    id: "wamid.reply123",
    channel: "whatsapp",
    channel_id: "123456789",
    user_id: "15551234567",
    username: "",
    content: "Replying to you",
    is_bot: False,
    reply_to_id: option.Some("wamid.original456"),
  )))
}

pub fn parse_invalid_json_error_test() {
  let result = whatsapp_adapter.parse_event(
    "{\"not\": \"a valid whatsapp event\"}"
  )
  should.equal(result, Error(port.SendFailed("invalid JSON")))
}

// --------------------------------------------------------------------------
// Message Building Tests
// --------------------------------------------------------------------------

pub fn build_text_reply_test() {
  let reply = port.ChannelReply(
    channel_id: "15551234567",
    content: "Hello back!",
    reply_to_id: option.None,
    interactive: option.None,
  )
  
  let result = whatsapp_adapter.build_reply_payload(reply)
  should.be_ok(result)
  
  let assert Ok(payload) = result
  // Verify it's valid JSON with expected structure
  should.equal(payload, "{\"messaging_product\":\"whatsapp\",\"to\":\"15551234567\",\"type\":\"text\",\"text\":{\"body\":\"Hello back!\"}}")
}

pub fn build_reply_payload_with_interactive_test() {
  let interactive = port.interactive_reply([
    port.text_block("Choose an option:"),
    port.buttons_block(buttons: [
      port.button(label: "Option 1", action_id: "opt1", style: port.ButtonPrimary),
      port.button(label: "Option 2", action_id: "opt2", style: port.ButtonSecondary),
    ]),
  ])
  
  let reply = port.ChannelReply(
    channel_id: "15551234567",
    content: "Choose an option:",
    reply_to_id: option.None,
    interactive: option.Some(interactive),
  )
  
  let result = whatsapp_adapter.build_reply_payload(reply)
  should.be_ok(result)
}

pub fn build_reply_to_message_test() {
  let reply = port.ChannelReply(
    channel_id: "15551234567",
    content: "Thread reply",
    reply_to_id: option.Some("wamid.original456"),
    interactive: option.None,
  )
  
  let result = whatsapp_adapter.build_reply_payload(reply)
  should.be_ok(result)
  
  let assert Ok(payload) = result
  // Verify reply contains the original message reference
  should.equal(payload, "{\"messaging_product\":\"whatsapp\",\"to\":\"15551234567\",\"type\":\"text\",\"text\":{\"body\":\"Thread reply\"},\"context\":{\"message_id\":\"wamid.original456\"}}")
}

// --------------------------------------------------------------------------
// Session Resolution Tests
// --------------------------------------------------------------------------

pub fn session_id_from_chat_test() {
  let msg = port.ChannelMessage(
    id: "wamid.123",
    channel: "whatsapp",
    channel_id: "123456789",
    user_id: "15551234567",
    username: "John",
    content: "Hello",
    is_bot: False,
    reply_to_id: option.None,
  )
  
  let session_id = whatsapp_adapter.resolve_session_id(msg)
  should.equal(session_id, "whatsapp:123456789:15551234567")
}

// --------------------------------------------------------------------------
// Sample Event Fixtures
// --------------------------------------------------------------------------

fn sample_text_message() -> String {
  "{\"object\":\"whatsapp_business_account\",\"entry\":[{\"id\":\"123456789\",\"changes\":[{\"value\":{\"messaging_product\":\"whatsapp\",\"metadata\":{\"phone_number_id\":\"123456789\",\"display_phone_number\":\"15551234567\"},\"contacts\":[{\"profile\":{\"name\":\"John Doe\"},\"wa_id\":\"15551234567\"}],\"messages\":[{\"from\":\"15551234567\",\"id\":\"wamid.1234567890\",\"timestamp\":\"1234567890\",\"type\":\"text\",\"text\":{\"body\":\"Hello, bot!\"}}]},\"field\":\"webhooks\"}]}]}"
}

fn sample_image_message() -> String {
  "{\"object\":\"whatsapp_business_account\",\"entry\":[{\"id\":\"123456789\",\"changes\":[{\"value\":{\"messaging_product\":\"whatsapp\",\"metadata\":{\"phone_number_id\":\"123456789\",\"display_phone_number\":\"15551234567\"},\"contacts\":[{\"profile\":{\"name\":\"John Doe\"},\"wa_id\":\"15551234567\"}],\"messages\":[{\"from\":\"15551234567\",\"id\":\"wamid.9876543210\",\"timestamp\":\"1234567890\",\"type\":\"image\",\"image\":{\"id\":\"img123\",\"mime_type\":\"image/jpeg\",\"sha256\":\"abc123\"},\"caption\":\"Check this image!\"}]},\"field\":\"webhooks\"}]}]}"
}

fn sample_audio_message() -> String {
  "{\"object\":\"whatsapp_business_account\",\"entry\":[{\"id\":\"123456789\",\"changes\":[{\"value\":{\"messaging_product\":\"whatsapp\",\"metadata\":{\"phone_number_id\":\"123456789\",\"display_phone_number\":\"15551234567\"},\"contacts\":[{\"profile\":{\"name\":\"John Doe\"},\"wa_id\":\"15551234567\"}],\"messages\":[{\"from\":\"15551234567\",\"id\":\"wamid.5555555555\",\"timestamp\":\"1234567890\",\"type\":\"audio\",\"audio\":{\"id\":\"audio123\",\"mime_type\":\"audio/ogg\",\"sha256\":\"def456\"}}]},\"field\":\"webhooks\"}]}]}"
}

fn sample_bot_message() -> String {
  // Bot's own phone number sending a message (should be filtered)
  "{\"object\":\"whatsapp_business_account\",\"entry\":[{\"id\":\"123456789\",\"changes\":[{\"value\":{\"messaging_product\":\"whatsapp\",\"metadata\":{\"phone_number_id\":\"123456789\",\"display_phone_number\":\"15550000000\"},\"contacts\":[{\"profile\":{\"name\":\"Bot\"},\"wa_id\":\"15550000000\"}],\"messages\":[{\"from\":\"15550000000\",\"id\":\"wamid.botmsg123\",\"timestamp\":\"1234567890\",\"type\":\"text\",\"text\":{\"body\":\"I'm the bot\"}}]},\"field\":\"webhooks\"}]}]}"
}

fn sample_empty_text_message() -> String {
  "{\"object\":\"whatsapp_business_account\",\"entry\":[{\"id\":\"123456789\",\"changes\":[{\"value\":{\"messaging_product\":\"whatsapp\",\"metadata\":{\"phone_number_id\":\"123456789\",\"display_phone_number\":\"15551234567\"},\"contacts\":[{\"profile\":{\"name\":\"John Doe\"},\"wa_id\":\"15551234567\"}],\"messages\":[{\"from\":\"15551234567\",\"id\":\"wamid.empty123\",\"timestamp\":\"1234567890\",\"type\":\"text\",\"text\":{\"body\":\"\"}}]},\"field\":\"webhooks\"}]}]}"
}

fn sample_status_update() -> String {
  "{\"object\":\"whatsapp_business_account\",\"entry\":[{\"id\":\"123456789\",\"changes\":[{\"value\":{\"messaging_product\":\"whatsapp\",\"metadata\":{\"phone_number_id\":\"123456789\",\"display_phone_number\":\"15551234567\"},\"statuses\":[{\"id\":\"wamid.status123\",\"from\":\"15551234567\",\"timestamp\":\"1234567890\",\"status\":\"delivered\"}]},\"field\":\"webhooks\"}]}]}"
}

fn sample_reply_message() -> String {
  "{\"object\":\"whatsapp_business_account\",\"entry\":[{\"id\":\"123456789\",\"changes\":[{\"value\":{\"messaging_product\":\"whatsapp\",\"metadata\":{\"phone_number_id\":\"123456789\",\"display_phone_number\":\"15551234567\"},\"contacts\":[{\"profile\":{\"name\":\"John Doe\"},\"wa_id\":\"15551234567\"}],\"messages\":[{\"from\":\"15551234567\",\"id\":\"wamid.reply123\",\"timestamp\":\"1234567890\",\"type\":\"text\",\"text\":{\"body\":\"Replying to you\"},\"context\":{\"from\":\"15551234567\",\"id\":\"wamid.original456\"}}]},\"field\":\"webhooks\"}]}]}"
}
