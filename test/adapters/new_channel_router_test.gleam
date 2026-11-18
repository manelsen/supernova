//// Smoke tests for shared channel routers.

import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/google_chat_router
import supernova/adapters/lark_router
import supernova/adapters/matrix_router
import supernova/adapters/mattermost_router
import supernova/adapters/slack_router
import supernova/adapters/wechat_work_router
import supernova/adapters/whatsapp_router
import supernova/channel/port
import supernova/llm/provider
import test_workspace

fn mock_provider_config() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}

pub fn matrix_router_smoke_test() {
  use _ <- test_workspace.with_isolated_workspace("new-router")
  let assert Ok(router) = matrix_router.start(mock_provider_config())
  let msg =
    port.ChannelMessage(
      id: "matrix-1",
      channel: "matrix",
      channel_id: "room-1",
      user_id: "u1",
      username: "alice",
      content: "hello",
      is_bot: False,
      reply_to_id: None,
    )
  let assert Ok(reply) = matrix_router.route(router, msg)
  reply.content |> should.equal("Mock response")
}

pub fn lark_router_smoke_test() {
  use _ <- test_workspace.with_isolated_workspace("new-router")
  let assert Ok(router) = lark_router.start(mock_provider_config())
  let msg =
    port.ChannelMessage(
      id: "lark-1",
      channel: "lark",
      channel_id: "chat-1",
      user_id: "u1",
      username: "alice",
      content: "hello",
      is_bot: False,
      reply_to_id: None,
    )
  let assert Ok(reply) = lark_router.route(router, msg)
  reply.content |> should.equal("Mock response")
}

pub fn google_chat_router_smoke_test() {
  use _ <- test_workspace.with_isolated_workspace("new-router")
  let assert Ok(router) = google_chat_router.start(mock_provider_config())
  let msg =
    port.ChannelMessage(
      id: "gc-1",
      channel: "google_chat",
      channel_id: "space-1",
      user_id: "u1",
      username: "alice",
      content: "hello",
      is_bot: False,
      reply_to_id: None,
    )
  let assert Ok(reply) = google_chat_router.route(router, msg)
  reply.content |> should.equal("Mock response")
}

pub fn slack_router_smoke_test() {
  use _ <- test_workspace.with_isolated_workspace("new-router")
  let assert Ok(router) = slack_router.start(mock_provider_config())
  let msg =
    port.ChannelMessage(
      id: "slack-1",
      channel: "slack",
      channel_id: "chan-1",
      user_id: "u1",
      username: "alice",
      content: "hello",
      is_bot: False,
      reply_to_id: None,
    )
  let assert Ok(reply) = slack_router.route(router, msg)
  reply.content |> should.equal("Mock response")
}

pub fn mattermost_router_smoke_test() {
  use _ <- test_workspace.with_isolated_workspace("new-router")
  let assert Ok(router) = mattermost_router.start(mock_provider_config())
  let msg =
    port.ChannelMessage(
      id: "mm-1",
      channel: "mattermost",
      channel_id: "chan-1",
      user_id: "u1",
      username: "alice",
      content: "hello",
      is_bot: False,
      reply_to_id: None,
    )
  let assert Ok(reply) = mattermost_router.route(router, msg)
  reply.content |> should.equal("Mock response")
}

pub fn wechat_work_router_smoke_test() {
  use _ <- test_workspace.with_isolated_workspace("new-router")
  let assert Ok(router) = wechat_work_router.start(mock_provider_config())
  let msg =
    port.ChannelMessage(
      id: "wcw-1",
      channel: "wechat_work",
      channel_id: "chat-1",
      user_id: "u1",
      username: "alice",
      content: "hello",
      is_bot: False,
      reply_to_id: None,
    )
  let assert Ok(reply) = wechat_work_router.route(router, msg)
  reply.content |> should.equal("Mock response")
}

pub fn whatsapp_router_smoke_test() {
  use _ <- test_workspace.with_isolated_workspace("new-router")
  let assert Ok(router) = whatsapp_router.start(mock_provider_config())
  let msg =
    port.ChannelMessage(
      id: "wa-1",
      channel: "whatsapp",
      channel_id: "chat-1",
      user_id: "u1",
      username: "alice",
      content: "hello",
      is_bot: False,
      reply_to_id: None,
    )
  let assert Ok(reply) = whatsapp_router.route(router, msg)
  reply.content |> should.equal("Mock response")
}

pub fn generic_router_channel_mismatch_test() {
  use _ <- test_workspace.with_isolated_workspace("new-router")
  let assert Ok(router) = matrix_router.start(mock_provider_config())
  let msg =
    port.ChannelMessage(
      id: "matrix-2",
      channel: "telegram",
      channel_id: "room-1",
      user_id: "u1",
      username: "alice",
      content: "hello",
      is_bot: False,
      reply_to_id: None,
    )

  case matrix_router.route(router, msg) {
    Error(port.Ignored(reason)) ->
      reason |> should.equal("channel mismatch: telegram")
    _ -> should.fail()
  }
}

pub fn matrix_router_model_command_falls_back_to_text_test() {
  use _ <- test_workspace.with_isolated_workspace("new-router")
  let assert Ok(router) = matrix_router.start(mock_provider_config())
  let msg =
    port.ChannelMessage(
      id: "matrix-model-1",
      channel: "matrix",
      channel_id: "room-model",
      user_id: "u2",
      username: "alice",
      content: "/model",
      is_bot: False,
      reply_to_id: None,
    )

  case matrix_router.route(router, msg) {
    Ok(reply) -> {
      reply.interactive |> should.equal(None)
      reply.content
      |> should.equal(
        "Current selection: Mock / mock-model\n"
        <> "Interactive picker is unavailable in matrix. "
        <> "Available models for Mock: mock-model, mock-alt-model",
      )
    }
    Error(_) -> should.fail()
  }
}

pub fn matrix_router_rejects_interactive_callbacks_test() {
  use _ <- test_workspace.with_isolated_workspace("new-router")
  let assert Ok(router) = matrix_router.start(mock_provider_config())
  let interaction =
    port.ChannelInteractionMessage(
      channel: "matrix",
      channel_id: "room-model",
      user_id: "u2",
      username: "alice",
      is_bot: False,
      event: port.ChannelInteractionEvent(
        id: "int-1",
        action_id: "picker_provider:openai",
        values: [],
        source_message_id: None,
      ),
    )

  case
    matrix_router.route_inbound(router, port.inbound_interaction(interaction))
  {
    Error(port.UnsupportedInteraction(reason)) ->
      reason
      |> should.equal("Interactive callbacks not supported for channel: matrix")
    _ -> should.fail()
  }
}

pub fn slack_router_model_command_returns_interactive_test() {
  use _ <- test_workspace.with_isolated_workspace("new-router")
  let assert Ok(router) = slack_router.start(mock_provider_config())
  let msg =
    port.ChannelMessage(
      id: "slack-model-1",
      channel: "slack",
      channel_id: "chan-model",
      user_id: "u2",
      username: "alice",
      content: "/models",
      is_bot: False,
      reply_to_id: None,
    )

  case slack_router.route(router, msg) {
    Ok(reply) -> {
      case reply.interactive {
        Some(_) -> Nil
        None -> should.fail()
      }
      string.contains(reply.content, "Mock") |> should.equal(True)
    }
    Error(_) -> should.fail()
  }
}
