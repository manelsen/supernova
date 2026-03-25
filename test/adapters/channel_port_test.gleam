//// Tests for channel port interaction-aware contract.

import gleam/option.{None, Some}
import gleeunit/should
import supernova/channel/port

fn sample_message() -> port.ChannelMessage {
  port.ChannelMessage(
    id: "msg-1",
    channel: "telegram",
    channel_id: "chat-1",
    user_id: "user-1",
    username: "alice",
    content: "hello",
    is_bot: False,
    reply_to_id: None,
  )
}

fn sample_interactive() -> port.ChannelInteractiveReply {
  let provider_button =
    port.button(
      label: "OpenAI",
      action_id: "select_provider:openai",
      style: port.ButtonPrimary,
    )

  let model_option = port.select_option(label: "gpt-4o", value: "openai/gpt-4o")

  port.interactive_reply([
    port.text_block("Select provider/model"),
    port.buttons_block([provider_button]),
    port.select_block(
      action_id: "select_model",
      placeholder: Some("Pick a model"),
      options: [model_option],
    ),
  ])
}

pub fn reply_builder_defaults_to_no_interactions_test() {
  let msg = sample_message()
  let reply = port.reply(to: msg, content: "pong")

  reply.channel_id |> should.equal("chat-1")
  reply.content |> should.equal("pong")
  reply.reply_to_id |> should.equal(None)
  reply.interactive |> should.equal(None)
}

pub fn reply_thread_builder_sets_reply_target_test() {
  let msg = sample_message()
  let reply = port.reply_thread(to: msg, content: "threaded")

  reply.channel_id |> should.equal("chat-1")
  reply.reply_to_id |> should.equal(Some("msg-1"))
  reply.interactive |> should.equal(None)
}

pub fn reply_with_interactions_builder_test() {
  let msg = sample_message()
  let interactive = sample_interactive()
  let reply =
    port.reply_with_interactions(
      to: msg,
      content: "Choose",
      interactive: interactive,
    )

  reply.reply_to_id |> should.equal(None)
  reply.interactive |> should.equal(Some(interactive))
}

pub fn reply_thread_with_interactions_builder_test() {
  let msg = sample_message()
  let interactive = sample_interactive()
  let reply =
    port.reply_thread_with_interactions(
      to: msg,
      content: "Choose in thread",
      interactive: interactive,
    )

  reply.reply_to_id |> should.equal(Some("msg-1"))
  reply.interactive |> should.equal(Some(interactive))
}

pub fn inbound_wrappers_preserve_payload_test() {
  let msg = sample_message()
  let wrapped_message = port.inbound_message(msg)

  case wrapped_message {
    port.InboundMessage(payload) -> {
      payload.id |> should.equal("msg-1")
      payload.channel |> should.equal("telegram")
    }
    _ -> should.fail()
  }

  let event =
    port.ChannelInteractionEvent(
      id: "cb-1",
      action_id: "select_provider:openai",
      values: ["openai"],
      source_message_id: Some("msg-1"),
    )

  let interaction =
    port.ChannelInteractionMessage(
      channel: "telegram",
      channel_id: "chat-1",
      user_id: "user-1",
      username: "alice",
      is_bot: False,
      event: event,
    )

  let wrapped_interaction = port.inbound_interaction(interaction)

  case wrapped_interaction {
    port.InboundInteraction(payload) -> {
      payload.channel |> should.equal("telegram")
      case payload.event {
        port.ChannelInteractionEvent(action_id:, values:, ..) -> {
          action_id |> should.equal("select_provider:openai")
          values |> should.equal(["openai"])
        }
      }
    }
    _ -> should.fail()
  }
}

pub fn unsupported_interaction_error_variant_test() {
  let error: port.ChannelError =
    port.UnsupportedInteraction(reason: "interactive callbacks not implemented")

  error
  |> unsupported_reason
  |> should.equal("interactive callbacks not implemented")
}

fn unsupported_reason(error: port.ChannelError) -> String {
  case error {
    port.UnsupportedInteraction(reason) -> reason
    _ -> ""
  }
}
