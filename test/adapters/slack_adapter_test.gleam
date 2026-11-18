import gleam/option
import gleam/string
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
  should.equal(
    event,
    Ok(port.ChannelMessage(
      id: "1234567890.123456",
      channel: "slack",
      channel_id: "C0123456789",
      user_id: "U012345678",
      username: "",
      content: " Hello bot!",
      is_bot: False,
      reply_to_id: option.None,
    )),
  )
}

pub fn parse_direct_message_test() {
  let event = slack_adapter.parse_event(sample_dm_event())
  should.equal(
    event,
    Ok(port.ChannelMessage(
      id: "1234567890.654321",
      channel: "slack",
      channel_id: "D012345678",
      user_id: "U012345679",
      username: "",
      content: "Direct message to bot",
      is_bot: False,
      reply_to_id: option.None,
    )),
  )
}

pub fn parse_event_callback_app_mention_test() {
  let event = slack_adapter.parse_event(sample_event_callback_mention_event())
  should.equal(
    event,
    Ok(port.ChannelMessage(
      id: "1234567890.123456",
      channel: "slack",
      channel_id: "C0123456789",
      user_id: "U012345678",
      username: "",
      content: " Hello bot!",
      is_bot: False,
      reply_to_id: option.None,
    )),
  )
}

pub fn parse_message_with_thread_test() {
  let event = slack_adapter.parse_event(sample_thread_event())
  should.equal(
    event,
    Ok(port.ChannelMessage(
      id: "1234567890.999999",
      channel: "slack",
      channel_id: "C0123456789",
      user_id: "U012345678",
      username: "",
      content: "Reply in thread",
      is_bot: False,
      reply_to_id: option.Some("1234567890.111111"),
    )),
  )
}

pub fn parse_bot_message_ignored_test() {
  let event = slack_adapter.parse_event(sample_bot_event())
  should.equal(event, Error(port.Ignored("bot sender filtered")))
}

pub fn parse_bot_subtype_message_ignored_test() {
  let event = slack_adapter.parse_event(sample_bot_subtype_event())
  should.equal(event, Error(port.Ignored("bot sender filtered")))
}

pub fn parse_empty_content_ignored_test() {
  let event = slack_adapter.parse_event(sample_empty_event())
  should.equal(event, Error(port.Ignored("empty content")))
}

pub fn parse_unsupported_subtype_ignored_test() {
  let event = slack_adapter.parse_event(sample_unsupported_subtype_event())
  should.equal(event, Error(port.Ignored("unsupported subtype: channel_join")))
}

pub fn parse_message_without_mention_preserves_content_test() {
  let assert Ok(message) = slack_adapter.parse_event(sample_plain_text_event())
  message.content |> should.equal("Hello without mention")
}

pub fn parse_malformed_mention_preserves_content_test() {
  let assert Ok(message) =
    slack_adapter.parse_event(sample_malformed_mention_event())
  message.content |> should.equal("Hello <@broken mention")
}

pub fn parse_invalid_json_error_test() {
  let result = slack_adapter.parse_event("{\"not\": \"a valid slack event\"}")
  should.equal(result, Error(port.SendFailed("invalid JSON")))
}

// --------------------------------------------------------------------------
// Message Building Tests
// --------------------------------------------------------------------------

pub fn build_text_reply_test() {
  let reply =
    port.ChannelReply(
      channel_id: "C0123456789",
      content: "Hello back!",
      reply_to_id: option.None,
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [],
    )

  let result = slack_adapter.build_reply_payload(reply)
  should.be_ok(result)
}

pub fn build_thread_reply_test() {
  let reply =
    port.ChannelReply(
      channel_id: "C0123456789",
      content: "Thread reply",
      reply_to_id: option.Some("1234567890.111111"),
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [],
    )

  let result = slack_adapter.build_reply_payload(reply)
  should.be_ok(result)
}

pub fn build_interactive_reply_payload_test() {
  let interactive =
    port.interactive_reply([
      port.buttons_block([
        port.button(
          label: "OpenAI",
          action_id: "picker_provider:openai",
          style: port.ButtonPrimary,
        ),
      ]),
      port.select_block(
        action_id: "picker_model_select",
        placeholder: option.Some("Select model"),
        options: [
          port.select_option("gpt-5.1", "openai/gpt-5.1"),
          port.select_option("gpt-4o", "openai/gpt-4o"),
        ],
      ),
    ])
  let reply =
    port.ChannelReply(
      channel_id: "C0123456789",
      content: "Choose provider",
      reply_to_id: option.None,
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.Some(interactive),
      media: [],
    )

  let assert Ok(payload) = slack_adapter.build_reply_payload(reply)

  string.contains(payload, "\"type\":\"actions\"") |> should.equal(True)
  string.contains(payload, "\"action_id\":\"picker_provider:openai\"")
  |> should.equal(True)
  string.contains(payload, "\"type\":\"static_select\"")
  |> should.equal(True)
  string.contains(payload, "\"action_id\":\"picker_model_select\"")
  |> should.equal(True)
}

pub fn build_chunked_reply_payloads_test() {
  let reply =
    port.ChannelReply(
      channel_id: "C0123456789",
      content: string.repeat("slack word ", 5000),
      reply_to_id: option.Some("1234567890.111111"),
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [],
    )

  let assert Ok(payloads) = slack_adapter.build_reply_payloads(reply)

  should.equal(list_length(payloads) > 1, True)

  case payloads {
    [first, second, ..] -> {
      string.contains(first, "\"thread_ts\":\"1234567890.111111\"")
      |> should.equal(True)
      string.contains(second, "\"thread_ts\":\"1234567890.111111\"")
      |> should.equal(True)
      string.contains(second, "(continued)")
      |> should.equal(True)
    }
    _ -> should.fail()
  }
}

pub fn progress_mode_uses_native_stream_for_dm_threads_test() {
  let reply =
    port.ChannelReply(
      channel_id: "D012345678",
      content: "",
      reply_to_id: option.Some("1721609600.123456"),
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [],
    )

  slack_adapter.progress_mode(reply)
  |> should.equal(slack_adapter.NativeStream)
}

pub fn progress_mode_falls_back_for_channel_threads_without_recipient_context_test() {
  let reply =
    port.ChannelReply(
      channel_id: "C0123456789",
      content: "",
      reply_to_id: option.Some("1721609600.123456"),
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [],
    )

  slack_adapter.progress_mode(reply)
  |> should.equal(slack_adapter.MessageUpdateFallback)
}

pub fn build_stream_start_payload_preserves_thread_ts_test() {
  let reply =
    port.ChannelReply(
      channel_id: "D012345678",
      content: "",
      reply_to_id: option.Some("1721609600.123456"),
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [],
    )

  let assert Ok(payload) = slack_adapter.build_stream_start_payload(reply)

  string.contains(payload, "\"channel\":\"D012345678\"")
  |> should.equal(True)
  string.contains(payload, "\"thread_ts\":\"1721609600.123456\"")
  |> should.equal(True)
  string.contains(payload, "\"markdown_text\":\"Thinking...\"")
  |> should.equal(True)
}

pub fn build_stream_start_payload_requires_thread_target_test() {
  let reply =
    port.ChannelReply(
      channel_id: "D012345678",
      content: "",
      reply_to_id: option.None,
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [],
    )

  should.equal(
    slack_adapter.build_stream_start_payload(reply),
    Error(port.SendFailed("Slack streaming requires thread_ts or reply_to_id")),
  )
}

pub fn build_stream_append_payload_includes_channel_ts_and_content_test() {
  let payload =
    slack_adapter.build_stream_append_payload(
      channel_id: "D012345678",
      stream_ts: "1730000000.999999",
      markdown_text: "delta",
    )

  string.contains(payload, "\"channel\":\"D012345678\"")
  |> should.equal(True)
  string.contains(payload, "\"ts\":\"1730000000.999999\"")
  |> should.equal(True)
  string.contains(payload, "\"markdown_text\":\"delta\"")
  |> should.equal(True)
}

pub fn build_stream_stop_payload_targets_stream_message_ts_test() {
  let payload =
    slack_adapter.build_stream_stop_payload(
      channel_id: "D012345678",
      stream_ts: "1730000000.999999",
      trailing_text: "done",
    )

  string.contains(payload, "\"channel\":\"D012345678\"")
  |> should.equal(True)
  string.contains(payload, "\"ts\":\"1730000000.999999\"")
  |> should.equal(True)
  string.contains(payload, "\"markdown_text\":\"done\"")
  |> should.equal(True)
}

pub fn build_stream_stop_payload_omits_markdown_text_when_empty_test() {
  let payload =
    slack_adapter.build_stream_stop_payload(
      channel_id: "D012345678",
      stream_ts: "1730000000.999999",
      trailing_text: "",
    )

  string.contains(payload, "\"markdown_text\"")
  |> should.equal(False)
}

// --------------------------------------------------------------------------
// Session Resolution Tests
// --------------------------------------------------------------------------

pub fn session_id_from_channel_test() {
  let msg =
    port.ChannelMessage(
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
  let msg =
    port.ChannelMessage(
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

pub fn start_returns_slack_channel_adapter_test() {
  let handler = fn(_, _) { Error(port.Ignored("not used in unit test")) }
  let assert Ok(adapter) =
    slack_adapter.start("xoxb-token", "signing-secret", handler)

  adapter.name |> should.equal("slack")
}

pub fn progress_mode_uses_fallback_without_thread_context_test() {
  let reply =
    port.ChannelReply(
      channel_id: "D012345678",
      content: "",
      reply_to_id: option.None,
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.None,
      media: [],
    )

  slack_adapter.progress_mode(reply)
  |> should.equal(slack_adapter.MessageUpdateFallback)
}

pub fn build_interactive_text_block_payload_test() {
  let reply =
    port.ChannelReply(
      channel_id: "C0123456789",
      content: "Choose",
      reply_to_id: option.None,
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.Some(
        port.interactive_reply([port.text_block("*Markdown text*")]),
      ),
      media: [],
    )

  let assert Ok(payload) = slack_adapter.build_reply_payload(reply)
  string.contains(payload, "\"type\":\"section\"")
  |> should.equal(True)
  string.contains(payload, "\"type\":\"mrkdwn\"")
  |> should.equal(True)
}

pub fn build_select_block_uses_default_placeholder_test() {
  let interactive =
    port.interactive_reply([
      port.select_block(
        action_id: "picker_model_select",
        placeholder: option.None,
        options: [port.select_option("gpt-5.1", "openai/gpt-5.1")],
      ),
    ])
  let reply =
    port.ChannelReply(
      channel_id: "C0123456789",
      content: "Select model",
      reply_to_id: option.None,
      thread_id: option.None,
      typing: False,
      edit_message_id: option.None,
      interactive: option.Some(interactive),
      media: [],
    )

  let assert Ok(payload) = slack_adapter.build_reply_payload(reply)
  string.contains(payload, "\"text\":\"Select an option\"")
  |> should.equal(True)
}

fn list_length(list: List(a)) -> Int {
  case list {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
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

fn sample_event_callback_mention_event() -> String {
  "{\"type\": \"event_callback\", \"team_id\": \"T012345678\", \"api_app_id\": \"A012345678\", \"event\": {\"type\": \"app_mention\", \"user\": \"U012345678\", \"text\": \"<@U999999999> Hello bot!\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.123456\", \"event_ts\": \"1234567890.123456\"}, \"event_id\": \"Ev012345678\", \"event_time\": 1234567890}"
}

fn sample_thread_event() -> String {
  "{\"type\": \"message\", \"user\": \"U012345678\", \"text\": \"Reply in thread\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.999999\", \"thread_ts\": \"1234567890.111111\", \"event_ts\": \"1234567890.999999\", \"channel_type\": \"channel\"}"
}

fn sample_bot_event() -> String {
  "{\"type\": \"message\", \"user\": \"B012345678\", \"text\": \"I'm a bot\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.777777\", \"event_ts\": \"1234567890.777777\", \"channel_type\": \"channel\", \"bot_id\": \"B012345678\"}"
}

fn sample_bot_subtype_event() -> String {
  "{\"type\": \"event_callback\", \"event\": {\"type\": \"message\", \"subtype\": \"bot_message\", \"user\": \"U012345678\", \"text\": \"bot text\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.777778\"}}"
}

fn sample_empty_event() -> String {
  "{\"type\": \"message\", \"user\": \"U012345678\", \"text\": \"\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.888888\", \"event_ts\": \"1234567890.888888\", \"channel_type\": \"channel\"}"
}

fn sample_unsupported_subtype_event() -> String {
  "{\"type\": \"message\", \"subtype\": \"channel_join\", \"user\": \"U012345678\", \"text\": \"joined\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.999998\", \"event_ts\": \"1234567890.999998\", \"channel_type\": \"channel\"}"
}

fn sample_plain_text_event() -> String {
  "{\"type\": \"message\", \"user\": \"U012345678\", \"text\": \"Hello without mention\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.999997\", \"event_ts\": \"1234567890.999997\", \"channel_type\": \"channel\"}"
}

fn sample_malformed_mention_event() -> String {
  "{\"type\": \"message\", \"user\": \"U012345678\", \"text\": \"Hello <@broken mention\", \"channel\": \"C0123456789\", \"ts\": \"1234567890.999996\", \"event_ts\": \"1234567890.999996\", \"channel_type\": \"channel\"}"
}
