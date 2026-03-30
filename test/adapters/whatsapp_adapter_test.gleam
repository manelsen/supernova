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
  should.equal(
    event,
    Ok(port.ChannelMessage(
      id: "3EB0C127D7BACC83D6A1",
      channel: "whatsapp",
      channel_id: "15551234567@s.whatsapp.net",
      user_id: "15551234567@s.whatsapp.net",
      username: "John Doe",
      content: "Hello, bot!",
      is_bot: False,
      reply_to_id: option.None,
    )),
  )
}

pub fn parse_media_message_test() {
  // Media message with caption
  let event = whatsapp_adapter.parse_event(sample_image_message())
  should.equal(
    event,
    Ok(port.ChannelMessage(
      id: "3EB0C127D7BACC83D6A3",
      channel: "whatsapp",
      channel_id: "15551234567@s.whatsapp.net",
      user_id: "15551234567@s.whatsapp.net",
      username: "John Doe",
      content: "Check this image!",
      is_bot: False,
      reply_to_id: option.None,
    )),
  )
}

pub fn parse_media_message_no_caption_test() {
  // Media messages without caption should be filtered as empty content
  let event = whatsapp_adapter.parse_event(sample_audio_message())
  should.equal(event, Error(port.Ignored("empty content")))
}

pub fn parse_bot_message_ignored_test() {
  // Message sent from the current device should be ignored
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
  should.equal(
    event,
    Error(port.Ignored("unsupported message type: delivered")),
  )
}

pub fn parse_reply_message_test() {
  // Message with reply context
  let event = whatsapp_adapter.parse_event(sample_reply_message())
  should.equal(
    event,
    Ok(port.ChannelMessage(
      id: "3EB0C127D7BACC83D6A2",
      channel: "whatsapp",
      channel_id: "15551234567@s.whatsapp.net",
      user_id: "15551234567@s.whatsapp.net",
      username: "John Doe",
      content: "Replying to you",
      is_bot: False,
      reply_to_id: option.Some("3EB0C127D7BACC83D6A1"),
    )),
  )
}

pub fn parse_invalid_json_error_test() {
  let result =
    whatsapp_adapter.parse_event("{\"not\": \"a valid whatsapp event\"}")
  should.equal(result, Error(port.SendFailed("invalid JSON")))
}

// --------------------------------------------------------------------------
// Message Building Tests
// --------------------------------------------------------------------------

pub fn build_text_reply_plan_test() {
  let reply =
    port.ChannelReply(
      channel_id: "15551234567@s.whatsapp.net",
      content: "Hello back!",
      reply_to_id: option.None,
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [],
    )

  should.equal(
    whatsapp_adapter.build_send_plan(reply),
    Ok(whatsapp_adapter.BridgeRequestPlan(
      path: "/send/message",
      content_type: whatsapp_adapter.BridgeJson,
      fields: [
        #("phone", "15551234567@s.whatsapp.net"),
        #("message", "Hello back!"),
      ],
      download: option.None,
    )),
  )
}

pub fn build_image_reply_plan_test() {
  let reply =
    port.ChannelReply(
      channel_id: "15551234567@s.whatsapp.net",
      content: "Check this image!",
      reply_to_id: option.None,
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [
        port.image_media(
          url: "https://example.com/image.jpg",
          alt_text: option.None,
        ),
      ],
    )

  should.equal(
    whatsapp_adapter.build_send_plan(reply),
    Ok(whatsapp_adapter.BridgeRequestPlan(
      path: "/send/image",
      content_type: whatsapp_adapter.BridgeMultipart,
      fields: [
        #("phone", "15551234567@s.whatsapp.net"),
        #("caption", "Check this image!"),
        #("image_url", "https://example.com/image.jpg"),
      ],
      download: option.None,
    )),
  )
}

pub fn build_audio_reply_plan_test() {
  let reply =
    port.ChannelReply(
      channel_id: "15551234567@s.whatsapp.net",
      content: "",
      reply_to_id: option.None,
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [
        port.audio_media(
          url: "https://example.com/audio.mp3",
          mime_type: option.Some("audio/mpeg"),
        ),
      ],
    )

  should.equal(
    whatsapp_adapter.build_send_plan(reply),
    Ok(whatsapp_adapter.BridgeRequestPlan(
      path: "/send/audio",
      content_type: whatsapp_adapter.BridgeMultipart,
      fields: [
        #("phone", "15551234567@s.whatsapp.net"),
        #("audio_url", "https://example.com/audio.mp3"),
      ],
      download: option.None,
    )),
  )
}

pub fn build_document_reply_plan_test() {
  let reply =
    port.ChannelReply(
      channel_id: "15551234567@s.whatsapp.net",
      content: "Monthly report",
      reply_to_id: option.None,
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [
        port.document_media(
          url: "https://example.com/report.pdf",
          filename: "report.pdf",
          mime_type: option.Some("application/pdf"),
        ),
      ],
    )

  should.equal(
    whatsapp_adapter.build_send_plan(reply),
    Ok(whatsapp_adapter.BridgeRequestPlan(
      path: "/send/file",
      content_type: whatsapp_adapter.BridgeMultipart,
      fields: [
        #("phone", "15551234567@s.whatsapp.net"),
        #("caption", "Monthly report"),
      ],
      download: option.Some(whatsapp_adapter.BridgeDownload(
        field_name: "file",
        source_url: "https://example.com/report.pdf",
        filename: "report.pdf",
        mime_type: option.Some("application/pdf"),
      )),
    )),
  )
}

pub fn build_reply_payload_with_interactive_falls_back_to_text_test() {
  let interactive =
    port.interactive_reply([
      port.text_block("Choose an option:"),
      port.buttons_block(buttons: [
        port.button(
          label: "Option 1",
          action_id: "opt1",
          style: port.ButtonPrimary,
        ),
      ]),
    ])

  let reply =
    port.ChannelReply(
      channel_id: "15551234567@s.whatsapp.net",
      content: "Choose an option:",
      reply_to_id: option.None,
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.Some(interactive),
      media: [],
    )

  should.equal(
    whatsapp_adapter.build_send_plan(reply),
    Ok(whatsapp_adapter.BridgeRequestPlan(
      path: "/send/message",
      content_type: whatsapp_adapter.BridgeJson,
      fields: [
        #("phone", "15551234567@s.whatsapp.net"),
        #("message", "Choose an option:"),
      ],
      download: option.None,
    )),
  )
}

pub fn build_reply_to_message_plan_test() {
  let reply =
    port.ChannelReply(
      channel_id: "15551234567@s.whatsapp.net",
      content: "Thread reply",
      reply_to_id: option.Some("3EB0C127D7BACC83D6A1"),
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [],
    )

  should.equal(
    whatsapp_adapter.build_send_plan(reply),
    Ok(whatsapp_adapter.BridgeRequestPlan(
      path: "/send/message",
      content_type: whatsapp_adapter.BridgeJson,
      fields: [
        #("phone", "15551234567@s.whatsapp.net"),
        #("message", "Thread reply"),
        #("reply_message_id", "3EB0C127D7BACC83D6A1"),
      ],
      download: option.None,
    )),
  )
}

// --------------------------------------------------------------------------
// Session Resolution Tests
// --------------------------------------------------------------------------

pub fn session_id_from_chat_test() {
  let msg =
    port.ChannelMessage(
      id: "wamid.123",
      channel: "whatsapp",
      channel_id: "15551234567@s.whatsapp.net",
      user_id: "15551234567@s.whatsapp.net",
      username: "John",
      content: "Hello",
      is_bot: False,
      reply_to_id: option.None,
    )

  let session_id = whatsapp_adapter.resolve_session_id(msg)
  should.equal(
    session_id,
    "whatsapp:15551234567@s.whatsapp.net:15551234567@s.whatsapp.net",
  )
}

// --------------------------------------------------------------------------
// Sample Event Fixtures
// --------------------------------------------------------------------------

fn sample_text_message() -> String {
  "{\"event\":\"message\",\"device_id\":\"15550000000@s.whatsapp.net\",\"payload\":{\"id\":\"3EB0C127D7BACC83D6A1\",\"chat_id\":\"15551234567@s.whatsapp.net\",\"from\":\"15551234567@s.whatsapp.net\",\"from_name\":\"John Doe\",\"timestamp\":\"2026-03-30T00:00:00Z\",\"is_from_me\":false,\"body\":\"Hello, bot!\"}}"
}

fn sample_image_message() -> String {
  "{\"event\":\"message\",\"device_id\":\"15550000000@s.whatsapp.net\",\"payload\":{\"id\":\"3EB0C127D7BACC83D6A3\",\"chat_id\":\"15551234567@s.whatsapp.net\",\"from\":\"15551234567@s.whatsapp.net\",\"from_name\":\"John Doe\",\"timestamp\":\"2026-03-30T00:00:00Z\",\"body\":\"Check this image!\",\"image\":{\"url\":\"https://mmg.whatsapp.net/media/image.jpg\",\"caption\":\"Check this image!\"}}}"
}

fn sample_audio_message() -> String {
  "{\"event\":\"message\",\"device_id\":\"15550000000@s.whatsapp.net\",\"payload\":{\"id\":\"3EB0C127D7BACC83D6A5\",\"chat_id\":\"15551234567@s.whatsapp.net\",\"from\":\"15551234567@s.whatsapp.net\",\"from_name\":\"John Doe\",\"timestamp\":\"2026-03-30T00:00:00Z\",\"audio\":\"statics/media/audio.ogg\"}}"
}

fn sample_bot_message() -> String {
  "{\"event\":\"message\",\"device_id\":\"15550000000@s.whatsapp.net\",\"payload\":{\"id\":\"3EB0C127D7BACC83D6AF\",\"chat_id\":\"15551234567@s.whatsapp.net\",\"from\":\"15550000000@s.whatsapp.net\",\"from_name\":\"Supernova\",\"timestamp\":\"2026-03-30T00:00:00Z\",\"is_from_me\":true,\"body\":\"I'm the bot\"}}"
}

fn sample_empty_text_message() -> String {
  "{\"event\":\"message\",\"device_id\":\"15550000000@s.whatsapp.net\",\"payload\":{\"id\":\"3EB0C127D7BACC83D6A0\",\"chat_id\":\"15551234567@s.whatsapp.net\",\"from\":\"15551234567@s.whatsapp.net\",\"from_name\":\"John Doe\",\"timestamp\":\"2026-03-30T00:00:00Z\",\"is_from_me\":false,\"body\":\"\"}}"
}

fn sample_status_update() -> String {
  "{\"object\":\"whatsapp_business_account\",\"entry\":[{\"id\":\"123456789\",\"changes\":[{\"value\":{\"messaging_product\":\"whatsapp\",\"metadata\":{\"phone_number_id\":\"123456789\",\"display_phone_number\":\"15551234567\"},\"statuses\":[{\"id\":\"wamid.status123\",\"from\":\"15551234567\",\"timestamp\":\"1234567890\",\"status\":\"delivered\"}]},\"field\":\"webhooks\"}]}]}"
}

fn sample_reply_message() -> String {
  "{\"event\":\"message\",\"device_id\":\"15550000000@s.whatsapp.net\",\"payload\":{\"id\":\"3EB0C127D7BACC83D6A2\",\"chat_id\":\"15551234567@s.whatsapp.net\",\"from\":\"15551234567@s.whatsapp.net\",\"from_name\":\"John Doe\",\"timestamp\":\"2026-03-30T00:00:00Z\",\"is_from_me\":false,\"body\":\"Replying to you\",\"replied_to_id\":\"3EB0C127D7BACC83D6A1\",\"quoted_body\":\"Hello, bot!\"}}"
}
