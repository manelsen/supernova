//// Tests for Telegram/Discord routers using the shared channel port contract.

import gleam/option.{None, Some}
import gleeunit/should
import supernova/adapters/discord_router
import supernova/adapters/discord_session
import supernova/adapters/telegram_router
import supernova/adapters/telegram_session
import supernova/channel/port
import supernova/llm/provider

fn mock_provider_config() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}

fn message(
  id: String,
  channel: String,
  channel_id: String,
  user_id: String,
  username: String,
  content: String,
  is_bot: Bool,
) -> port.ChannelMessage {
  port.ChannelMessage(
    id: id,
    channel: channel,
    channel_id: channel_id,
    user_id: user_id,
    username: username,
    content: content,
    is_bot: is_bot,
    reply_to_id: None,
  )
}

fn interaction(
  channel: String,
  channel_id: String,
  user_id: String,
  username: String,
  action_id: String,
  values: List(String),
) -> port.ChannelInteractionMessage {
  port.ChannelInteractionMessage(
    channel: channel,
    channel_id: channel_id,
    user_id: user_id,
    username: username,
    is_bot: False,
    event: port.ChannelInteractionEvent(
      id: "interaction-1",
      action_id: action_id,
      values: values,
      source_message_id: None,
    ),
  )
}

pub fn telegram_router_routes_message_test() {
  let assert Ok(session_mgr) = telegram_session.start()
  let assert Ok(router) =
    telegram_router.start(session_mgr, mock_provider_config())
  let msg =
    message(
      "tg-msg-1",
      "telegram",
      "chat-1",
      "user-1",
      "alice",
      "hello telegram",
      False,
    )

  let result = telegram_router.route(router, msg)

  case result {
    Ok(reply) -> {
      reply.channel_id |> should.equal("chat-1")
      reply.content |> should.equal("Mock response")
      reply.reply_to_id |> should.equal(None)
    }
    Error(_) -> should.fail()
  }
}

pub fn telegram_router_ignores_bot_test() {
  let assert Ok(session_mgr) = telegram_session.start()
  let assert Ok(router) =
    telegram_router.start(session_mgr, mock_provider_config())
  let msg =
    message("tg-msg-2", "telegram", "chat-2", "bot-1", "my-bot", "beep", True)

  let result = telegram_router.route(router, msg)

  case result {
    Error(port.Ignored(reason)) -> reason |> should.equal("bot message")
    _ -> should.fail()
  }
}

pub fn discord_router_routes_message_test() {
  let assert Ok(session_mgr) = discord_session.start()
  let assert Ok(router) =
    discord_router.start(session_mgr, mock_provider_config())
  let msg =
    message(
      "dc-msg-1",
      "discord",
      "channel-1",
      "user-1",
      "bob",
      "hello discord",
      False,
    )

  let result = discord_router.route(router, msg)

  case result {
    Ok(reply) -> {
      reply.channel_id |> should.equal("channel-1")
      reply.content |> should.equal("Mock response")
      reply.reply_to_id |> should.equal(None)
    }
    Error(_) -> should.fail()
  }
}

pub fn discord_router_channel_mismatch_test() {
  let assert Ok(session_mgr) = discord_session.start()
  let assert Ok(router) =
    discord_router.start(session_mgr, mock_provider_config())
  let msg =
    message(
      "dc-msg-2",
      "telegram",
      "channel-2",
      "user-2",
      "eve",
      "hello",
      False,
    )

  let result = discord_router.route(router, msg)

  case result {
    Error(port.Ignored(reason)) ->
      reason |> should.equal("channel mismatch: telegram")
    _ -> should.fail()
  }
}

pub fn telegram_router_model_command_returns_interactive_picker_test() {
  let assert Ok(session_mgr) = telegram_session.start()
  let assert Ok(router) =
    telegram_router.start(session_mgr, mock_provider_config())
  let msg =
    message(
      "tg-model-1",
      "telegram",
      "chat-model",
      "user-1",
      "alice",
      "/model",
      False,
    )

  case telegram_router.route(router, msg) {
    Ok(reply) -> {
      reply.channel_id |> should.equal("chat-model")
      reply.content
      |> should.equal(
        "Current selection: Mock / mock-model\n"
        <> "Choose provider and model for this session.",
      )
      case reply.interactive {
        Some(interactive) ->
          case interactive.blocks {
            [
              port.InteractionText(text: "Provider: Mock"),
              port.InteractionButtons(buttons),
              port.InteractionSelect(
                action_id: "picker_model_select",
                placeholder: Some("Select model"),
                options: options,
              ),
            ] -> {
              buttons
              |> should.equal([
                port.ChannelButton(
                  label: "Mock",
                  action_id: "picker_provider:mock",
                  style: port.ButtonSuccess,
                ),
                port.ChannelButton(
                  label: "OpenAI",
                  action_id: "picker_provider:openai",
                  style: port.ButtonPrimary,
                ),
                port.ChannelButton(
                  label: "Anthropic",
                  action_id: "picker_provider:anthropic",
                  style: port.ButtonPrimary,
                ),
                port.ChannelButton(
                  label: "OpenRouter",
                  action_id: "picker_provider:openrouter",
                  style: port.ButtonPrimary,
                ),
                port.ChannelButton(
                  label: "OpenCode Zen",
                  action_id: "picker_provider:opencode_zen",
                  style: port.ButtonPrimary,
                ),
                port.ChannelButton(
                  label: "Zhipu",
                  action_id: "picker_provider:zhipu",
                  style: port.ButtonPrimary,
                ),
                port.ChannelButton(
                  label: "Zhipu Coding",
                  action_id: "picker_provider:zhipu_coding",
                  style: port.ButtonPrimary,
                ),
                port.ChannelButton(
                  label: "MiniMax",
                  action_id: "picker_provider:minimax",
                  style: port.ButtonPrimary,
                ),
              ])
              options
              |> should.equal([
                port.ChannelSelectOption(
                  label: "[active] mock-model",
                  value: "mock|mock-model",
                ),
                port.ChannelSelectOption(
                  label: "mock-alt-model",
                  value: "mock|mock-alt-model",
                ),
              ])
            }
            _ -> should.fail()
          }
        None -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn telegram_router_model_selection_updates_session_picker_test() {
  let assert Ok(session_mgr) = telegram_session.start()
  let assert Ok(router) =
    telegram_router.start(session_mgr, mock_provider_config())

  let model_selection =
    interaction(
      "telegram",
      "chat-ux",
      "user-42",
      "alice",
      "picker_model_select",
      ["mock|mock-alt-model"],
    )

  case
    telegram_router.route_inbound(
      router,
      port.inbound_interaction(model_selection),
    )
  {
    Ok(reply) -> {
      reply.content
      |> should.equal("Model set to mock-alt-model for this session.")
    }
    Error(_) -> should.fail()
  }

  let show_picker =
    message(
      "tg-model-2",
      "telegram",
      "chat-ux",
      "user-42",
      "alice",
      "/models",
      False,
    )

  case telegram_router.route(router, show_picker) {
    Ok(reply) ->
      case reply.interactive {
        Some(interactive) ->
          case interactive.blocks {
            [_, _, port.InteractionSelect(options: options, ..)] ->
              options
              |> should.equal([
                port.ChannelSelectOption(
                  label: "mock-model",
                  value: "mock|mock-model",
                ),
                port.ChannelSelectOption(
                  label: "[active] mock-alt-model",
                  value: "mock|mock-alt-model",
                ),
              ])
            _ -> should.fail()
          }
        None -> should.fail()
      }
    Error(_) -> should.fail()
  }
}

pub fn discord_router_provider_interaction_returns_openai_picker_test() {
  let assert Ok(session_mgr) = discord_session.start()
  let assert Ok(router) =
    discord_router.start(session_mgr, mock_provider_config())

  let provider_selection =
    interaction(
      "discord",
      "channel-ux",
      "user-9",
      "bob",
      "picker_provider:openai",
      [],
    )

  case
    discord_router.route_inbound(
      router,
      port.inbound_interaction(provider_selection),
    )
  {
    Ok(reply) -> {
      reply.content |> should.equal("Provider set to OpenAI. Select a model.")
      case reply.interactive {
        Some(interactive) ->
          case interactive.blocks {
            [
              port.InteractionText(text: "Provider: OpenAI"),
              _,
              port.InteractionSelect(options: options, ..),
            ] ->
              options
              |> should.equal([
                port.ChannelSelectOption(
                  label: "[active] gpt-5-mini",
                  value: "openai|gpt-5-mini",
                ),
                port.ChannelSelectOption(
                  label: "gpt-4.1",
                  value: "openai|gpt-4.1",
                ),
                port.ChannelSelectOption(
                  label: "gpt-4o",
                  value: "openai|gpt-4o",
                ),
              ])
            _ -> should.fail()
          }
        None -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn discord_router_unknown_interaction_returns_error_test() {
  let assert Ok(session_mgr) = discord_session.start()
  let assert Ok(router) =
    discord_router.start(session_mgr, mock_provider_config())

  let unknown =
    interaction(
      "discord",
      "channel-err",
      "user-77",
      "bob",
      "picker_unknown_action",
      [],
    )

  case discord_router.route_inbound(router, port.inbound_interaction(unknown)) {
    Error(port.UnsupportedInteraction(reason)) ->
      reason
      |> should.equal("Unsupported interaction action: picker_unknown_action")
    _ -> should.fail()
  }
}

pub fn telegram_router_start_bootstraps_session_test() {
  let assert Ok(session_mgr) = telegram_session.start()
  let assert Ok(router) =
    telegram_router.start(session_mgr, mock_provider_config())
  let start_msg =
    message(
      "tg-start-1",
      "telegram",
      "chat-bootstrap",
      "user-bootstrap",
      "alice",
      "/start",
      False,
    )

  case telegram_router.route(router, start_msg) {
    Ok(reply) ->
      reply.content
      |> should.equal(
        "Session bootstrapped.\nAgent: agent:user-bootstrap\nModel: mock-model",
      )
    Error(_) -> should.fail()
  }
}

pub fn telegram_router_status_reports_bootstrap_state_test() {
  let assert Ok(session_mgr) = telegram_session.start()
  let assert Ok(router) =
    telegram_router.start(session_mgr, mock_provider_config())
  let status_msg =
    message(
      "tg-status-1",
      "telegram",
      "chat-status",
      "user-status",
      "alice",
      "/status",
      False,
    )

  case telegram_router.route(router, status_msg) {
    Ok(reply) ->
      reply.content
      |> should.equal(
        "Session status: not started\n"
        <> "Agent: agent:user-status\n"
        <> "Provider: Mock\n"
        <> "Model: mock-model",
      )
    Error(_) -> should.fail()
  }

  let start_msg =
    message(
      "tg-status-2",
      "telegram",
      "chat-status",
      "user-status",
      "alice",
      "/start",
      False,
    )
  let assert Ok(_) = telegram_router.route(router, start_msg)

  let status_after_start =
    message(
      "tg-status-3",
      "telegram",
      "chat-status",
      "user-status",
      "alice",
      "/status",
      False,
    )

  case telegram_router.route(router, status_after_start) {
    Ok(reply) ->
      reply.content
      |> should.equal(
        "Session status: ready\n"
        <> "Agent: agent:user-status\n"
        <> "Provider: Mock\n"
        <> "Model: mock-model",
      )
    Error(_) -> should.fail()
  }
}

pub fn discord_router_help_uses_channel_specific_text_test() {
  let assert Ok(session_mgr) = discord_session.start()
  let assert Ok(router) =
    discord_router.start(session_mgr, mock_provider_config())
  let help_msg =
    message(
      "dc-help-1",
      "discord",
      "channel-help",
      "user-help",
      "bob",
      "/help",
      False,
    )

  case discord_router.route(router, help_msg) {
    Ok(reply) ->
      reply.content
      |> should.equal(
        "Supernova AI Agent Framework\n\n"
        <> "Commands:\n"
        <> "/help - Show this help\n"
        <> "/start - Start a new session\n"
        <> "/status - Show session status\n"
        <> "/model - Change LLM model\n"
        <> "/project - Start project wizard\n",
      )
    Error(_) -> should.fail()
  }
}
