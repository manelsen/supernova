//// Tests for Telegram/Discord routers using the shared channel port contract.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/discord_router
import supernova/adapters/telegram_router
import supernova/channel/port
import supernova/channel/session
import supernova/core/persona/loader as persona_loader
import supernova/core/session/history_store
import supernova/core/session/server
import supernova/core/session/supervisor
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

fn complete_telegram_bootstrap(
  router: telegram_router.TelegramRouter,
  channel_id: String,
  user_id: String,
  username: String,
) -> Nil {
  [
    "/reset-identity",
    "Aurora",
    "Curiosa e técnica.",
    "Respostas curtas em português.",
    "Pode me chamar de Micelio.",
  ]
  |> list.each(fn(content) {
    let msg =
      message(
        "tg-bootstrap-" <> content,
        "telegram",
        channel_id,
        user_id,
        username,
        content,
        False,
      )
    let _ = telegram_router.route(router, msg)
    Nil
  })
}

pub fn telegram_router_routes_message_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = telegram_router.start(mock_provider_config())
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

pub fn telegram_router_runs_tool_loop_until_final_response_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = telegram_router.start(mock_provider_config())
  let msg =
    message(
      "tg-tools-1",
      "telegram",
      "chat-tools",
      "user-1",
      "alice",
      "[tool-loop-success] run builtin tools",
      False,
    )

  case telegram_router.route(router, msg) {
    Ok(reply) -> {
      reply.channel_id |> should.equal("chat-tools")
      reply.content |> should.equal("Mock tool success")
    }
    Error(_) -> should.fail()
  }
}

pub fn telegram_router_returns_final_tool_error_response_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = telegram_router.start(mock_provider_config())
  let msg =
    message(
      "tg-tools-2",
      "telegram",
      "chat-tools",
      "user-1",
      "alice",
      "[tool-loop-error] run builtin tools",
      False,
    )

  case telegram_router.route(router, msg) {
    Ok(reply) -> {
      reply.channel_id |> should.equal("chat-tools")
      reply.content |> should.equal("Mock tool error")
    }
    Error(_) -> should.fail()
  }
}

pub fn telegram_router_ignores_bot_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = telegram_router.start(mock_provider_config())
  let msg =
    message("tg-msg-2", "telegram", "chat-2", "bot-1", "my-bot", "beep", True)

  let result = telegram_router.route(router, msg)

  case result {
    Error(port.Ignored(reason)) -> reason |> should.equal("bot message")
    _ -> should.fail()
  }
}

pub fn discord_router_routes_message_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = discord_router.start(mock_provider_config())
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
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = discord_router.start(mock_provider_config())
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
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = telegram_router.start(mock_provider_config())
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
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = telegram_router.start(mock_provider_config())

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

  let status_msg =
    message(
      "tg-model-3",
      "telegram",
      "chat-ux",
      "user-42",
      "alice",
      "/status",
      False,
    )

  case telegram_router.route(router, status_msg) {
    Ok(reply) ->
      reply.content
      |> should.equal(
        "Session status: not started\n"
        <> "Agent: telegram:user-42\n"
        <> "Provider: Mock\n"
        <> "Model: mock-alt-model",
      )
    Error(_) -> should.fail()
  }
}

pub fn telegram_router_invalid_provider_selection_falls_back_to_default_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = telegram_router.start(mock_provider_config())

  let selection =
    interaction(
      "telegram",
      "chat-fallback",
      "user-42",
      "alice",
      "picker_model_select",
      ["ghost|strange-model"],
    )

  case
    telegram_router.route_inbound(router, port.inbound_interaction(selection))
  {
    Ok(reply) ->
      reply.content
      |> should.equal("Model set to mock-model for this session.")
    Error(_) -> should.fail()
  }

  let status_msg =
    message(
      "tg-fallback-1",
      "telegram",
      "chat-fallback",
      "user-42",
      "alice",
      "/status",
      False,
    )

  case telegram_router.route(router, status_msg) {
    Ok(reply) ->
      reply.content
      |> should.equal(
        "Session status: not started\n"
        <> "Agent: telegram:user-42\n"
        <> "Provider: Mock\n"
        <> "Model: mock-model",
      )
    Error(_) -> should.fail()
  }
}

pub fn telegram_router_interaction_reply_edits_source_message_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = telegram_router.start(mock_provider_config())

  let selection =
    port.ChannelInteractionMessage(
      channel: "telegram",
      channel_id: "chat-edit",
      user_id: "user-42",
      username: "alice",
      is_bot: False,
      event: port.ChannelInteractionEvent(
        id: "interaction-edit-1",
        action_id: "picker_model_select",
        values: ["mock|mock-alt-model"],
        source_message_id: Some("55"),
      ),
    )

  case
    telegram_router.route_inbound(router, port.inbound_interaction(selection))
  {
    Ok(reply) -> {
      reply.content
      |> should.equal("Model set to mock-alt-model for this session.")
      reply.reply_to_id |> should.equal(Some("55"))
      reply.edit_message_id |> should.equal(Some("55"))
    }
    Error(_) -> should.fail()
  }
}

pub fn discord_router_provider_interaction_returns_openai_picker_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = discord_router.start(mock_provider_config())

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
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = discord_router.start(mock_provider_config())

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
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = telegram_router.start(mock_provider_config())
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
        "Session bootstrapped.\nAgent: telegram:user-bootstrap\nModel: mock-model",
      )
    Error(_) -> should.fail()
  }
}

pub fn telegram_router_status_reports_bootstrap_state_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = telegram_router.start(mock_provider_config())
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
        <> "Agent: telegram:user-status\n"
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
        <> "Agent: telegram:user-status\n"
        <> "Provider: Mock\n"
        <> "Model: mock-model",
      )
    Error(_) -> should.fail()
  }
}

pub fn telegram_router_help_uses_channel_specific_text_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = telegram_router.start(mock_provider_config())
  let help_msg =
    message(
      "tg-help-1",
      "telegram",
      "chat-help",
      "user-help",
      "alice",
      "/help",
      False,
    )

  case telegram_router.route(router, help_msg) {
    Ok(reply) ->
      reply.content
      |> should.equal(
        "Supernova AI Agent Framework\n\n"
        <> "Commands:\n"
        <> "/start - Start a new session\n"
        <> "/help - Show this help\n"
        <> "/status - Show session status\n"
        <> "/commands - List all commands\n"
        <> "/reasoning - Toggle reasoning mode\n"
        <> "/model - Change LLM model\n",
      )
    Error(_) -> should.fail()
  }
}

pub fn discord_router_start_bootstraps_session_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = discord_router.start(mock_provider_config())
  let start_msg =
    message(
      "dc-start-1",
      "discord",
      "channel-bootstrap",
      "user-bootstrap",
      "bob",
      "/start",
      False,
    )

  case discord_router.route(router, start_msg) {
    Ok(reply) ->
      reply.content
      |> should.equal(
        "Session bootstrapped.\nAgent: discord:user-bootstrap\nModel: mock-model",
      )
    Error(_) -> should.fail()
  }
}

pub fn discord_router_status_reports_bootstrap_state_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = discord_router.start(mock_provider_config())
  let status_msg =
    message(
      "dc-status-1",
      "discord",
      "channel-status",
      "user-status",
      "bob",
      "/status",
      False,
    )

  case discord_router.route(router, status_msg) {
    Ok(reply) ->
      reply.content
      |> should.equal(
        "Session status: not started\n"
        <> "Agent: discord:user-status\n"
        <> "Provider: Mock\n"
        <> "Model: mock-model",
      )
    Error(_) -> should.fail()
  }

  let start_msg =
    message(
      "dc-status-2",
      "discord",
      "channel-status",
      "user-status",
      "bob",
      "/start",
      False,
    )
  let assert Ok(_) = discord_router.route(router, start_msg)

  let status_after_start =
    message(
      "dc-status-3",
      "discord",
      "channel-status",
      "user-status",
      "bob",
      "/status",
      False,
    )

  case discord_router.route(router, status_after_start) {
    Ok(reply) ->
      reply.content
      |> should.equal(
        "Session status: ready\n"
        <> "Agent: discord:user-status\n"
        <> "Provider: Mock\n"
        <> "Model: mock-model",
      )
    Error(_) -> should.fail()
  }
}

pub fn discord_router_model_command_returns_interactive_picker_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = discord_router.start(mock_provider_config())
  let msg =
    message(
      "dc-model-1",
      "discord",
      "channel-model",
      "user-model",
      "bob",
      "/model",
      False,
    )

  case discord_router.route(router, msg) {
    Ok(reply) -> {
      reply.channel_id |> should.equal("channel-model")
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
              port.InteractionButtons(_),
              port.InteractionSelect(
                action_id: "picker_model_select",
                placeholder: Some("Select model"),
                options: options,
              ),
            ] ->
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
            _ -> should.fail()
          }
        None -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn telegram_router_records_history_in_supervised_session_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(session_sup) = supervisor.start()
  let assert Ok(router) =
    telegram_router.start_with_session_supervisor(
      session_sup,
      mock_provider_config(),
    )
  complete_telegram_bootstrap(router, "chat-history", "user-history", "alice")

  let first_msg =
    message(
      "tg-history-1",
      "telegram",
      "chat-history",
      "user-history",
      "alice",
      "first turn",
      False,
    )
  let second_msg =
    message(
      "tg-history-2",
      "telegram",
      "chat-history",
      "user-history",
      "alice",
      "second turn",
      False,
    )

  let assert Ok(_) = telegram_router.route(router, first_msg)
  let assert Ok(_) = telegram_router.route(router, second_msg)
  let session_id = session.telegram_session_id("chat-history", "user-history")

  supervisor.list_sessions(session_sup)
  |> should.equal([session_id])

  let assert Ok(session) = supervisor.get_session(session_sup, session_id)
  server.get_history(session)
  |> should.equal([
    server.ChatMessage(role: "user", content: "first turn"),
    server.ChatMessage(role: "assistant", content: "Mock response"),
    server.ChatMessage(role: "user", content: "second turn"),
    server.ChatMessage(role: "assistant", content: "Mock response"),
  ])
}

/// A restart (a new supervisor over the same data directory) keeps the
/// conversation: the next turn continues it, and the model sees it.
pub fn telegram_router_conversation_survives_a_restart_test() {
  use dir <- test_workspace.with_isolated_workspace("channel-router-restart")
  let store = history_store.HistoryStore(data_dir: dir, limit: 40, kept: 40)
  let turn = fn(id, text) {
    message(id, "telegram", "chat-r", "user-r", "alice", text, False)
  }

  let assert Ok(before) = supervisor.start_with_history(store)
  let assert Ok(router) =
    telegram_router.start_with_session_supervisor(
      before,
      mock_provider_config(),
    )
  complete_telegram_bootstrap(router, "chat-r", "user-r", "alice")
  let assert Ok(_) =
    telegram_router.route(router, turn("tg-r-1", "antes do restart"))
  supervisor.stop(before)

  let assert Ok(after) = supervisor.start_with_history(store)
  let assert Ok(router) =
    telegram_router.start_with_session_supervisor(after, mock_provider_config())
  let assert Ok(_) =
    telegram_router.route(router, turn("tg-r-2", "depois do restart"))

  let session_id = session.telegram_session_id("chat-r", "user-r")
  let assert Ok(session) = supervisor.get_session(after, session_id)
  server.get_history(session)
  |> list.map(fn(message) { message.content })
  |> list.filter(fn(content) { string.contains(content, "restart") })
  |> should.equal(["antes do restart", "depois do restart"])
  supervisor.stop(after)
}

pub fn telegram_router_handler_streams_and_records_history_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(session_sup) = supervisor.start()
  let assert Ok(router) =
    telegram_router.start_with_session_supervisor(
      session_sup,
      mock_provider_config(),
    )
  complete_telegram_bootstrap(router, "chat-stream", "user-stream", "alice")
  let msg =
    message(
      "tg-stream-1",
      "telegram",
      "chat-stream",
      "user-stream",
      "alice",
      "stream this reply",
      False,
    )
  let events = process.new_subject()

  case
    telegram_router.route_inbound_for_handler(
      router,
      port.inbound_message(msg),
      events,
    )
  {
    Ok(port.StreamReply(base_reply)) -> {
      base_reply.channel_id |> should.equal("chat-stream")
      base_reply.typing |> should.equal(True)

      let assert Ok(first) = process.receive(events, within: 1000)
      let assert Ok(second) = process.receive(events, within: 1000)
      let assert Ok(third) = process.receive(events, within: 1000)
      let assert Ok(fourth) = process.receive(events, within: 1000)

      first
      |> should.equal(port.StreamUpdate(port.reply(to: msg, content: "Mock ")))
      second
      |> should.equal(
        port.StreamUpdate(port.reply(to: msg, content: "Mock streaming ")),
      )
      third
      |> should.equal(
        port.StreamUpdate(port.reply(
          to: msg,
          content: "Mock streaming response",
        )),
      )
      fourth
      |> should.equal(
        port.StreamComplete(port.reply(
          to: msg,
          content: "Mock streaming response",
        )),
      )
    }
    _ -> should.fail()
  }

  let session_id = session.telegram_session_id("chat-stream", "user-stream")
  let assert Ok(session) = supervisor.get_session(session_sup, session_id)
  server.get_history(session)
  |> should.equal([
    server.ChatMessage(role: "user", content: "stream this reply"),
    server.ChatMessage(role: "assistant", content: "Mock streaming response"),
  ])
}

pub fn telegram_router_supervised_first_message_starts_identity_bootstrap_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(session_sup) = supervisor.start()
  let assert Ok(router) =
    telegram_router.start_with_session_supervisor(
      session_sup,
      mock_provider_config(),
    )

  let msg =
    message(
      "tg-prd-bootstrap-1",
      "telegram",
      "chat-prd-bootstrap",
      "user-prd-bootstrap",
      "alice",
      "olá",
      False,
    )

  case telegram_router.route(router, msg) {
    Ok(reply) ->
      string.contains(reply.content, "Como você quer me chamar?")
      |> should.equal(True)
    Error(_) -> should.fail()
  }
}

pub fn telegram_router_supervised_bootstrap_writes_persona_files_test() {
  use root <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(session_sup) = supervisor.start()
  let assert Ok(router) =
    telegram_router.start_with_session_supervisor(
      session_sup,
      mock_provider_config(),
    )

  let first =
    message(
      "tg-prd-bootstrap-2-1",
      "telegram",
      "chat-prd-bootstrap-2",
      "user-prd-bootstrap-2",
      "alice",
      "/reset-identity",
      False,
    )
  let second =
    message(
      "tg-prd-bootstrap-2-2",
      "telegram",
      "chat-prd-bootstrap-2",
      "user-prd-bootstrap-2",
      "alice",
      "Aurora",
      False,
    )
  let third =
    message(
      "tg-prd-bootstrap-2-3",
      "telegram",
      "chat-prd-bootstrap-2",
      "user-prd-bootstrap-2",
      "alice",
      "Curiosa e direta.",
      False,
    )
  let fourth =
    message(
      "tg-prd-bootstrap-2-4",
      "telegram",
      "chat-prd-bootstrap-2",
      "user-prd-bootstrap-2",
      "alice",
      "Respostas curtas, sem emojis.",
      False,
    )
  let fifth =
    message(
      "tg-prd-bootstrap-2-5",
      "telegram",
      "chat-prd-bootstrap-2",
      "user-prd-bootstrap-2",
      "alice",
      "Me chame de Micelio.",
      False,
    )

  let assert Ok(r1) = telegram_router.route(router, first)
  let assert Ok(r2) = telegram_router.route(router, second)
  let assert Ok(r3) = telegram_router.route(router, third)
  let assert Ok(r4) = telegram_router.route(router, fourth)
  let assert Ok(r5) = telegram_router.route(router, fifth)

  string.contains(r1.content, "Como você quer me chamar?") |> should.equal(True)
  string.contains(
    r2.content,
    "Que tipo de personalidade você quer que eu tenha?",
  )
  |> should.equal(True)
  string.contains(r3.content, "Como prefere que eu me comunique?")
  |> should.equal(True)
  string.contains(r4.content, "E como devo te chamar?")
  |> should.equal(True)
  string.contains(r5.content, "Pronto! Sou Aurora agora.")
  |> should.equal(True)

  let workspace_path = root <> "/telegram:user-prd-bootstrap-2"
  let assert Ok(persona) = persona_loader.load(workspace_path)
  string.contains(persona.identity, "**Nome:** Aurora")
  |> should.equal(True)
}

pub fn telegram_router_reset_identity_restarts_bootstrap_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(session_sup) = supervisor.start()
  let assert Ok(router) =
    telegram_router.start_with_session_supervisor(
      session_sup,
      mock_provider_config(),
    )
  complete_telegram_bootstrap(
    router,
    "chat-prd-bootstrap-reset",
    "user-prd-bootstrap-reset",
    "alice",
  )

  let reset_msg =
    message(
      "tg-prd-bootstrap-reset-1",
      "telegram",
      "chat-prd-bootstrap-reset",
      "user-prd-bootstrap-reset",
      "alice",
      "/reset-identity",
      False,
    )

  case telegram_router.route(router, reset_msg) {
    Ok(reply) ->
      string.contains(reply.content, "Como você quer me chamar?")
      |> should.equal(True)
    Error(_) -> should.fail()
  }
}

pub fn telegram_router_updates_self_state_after_successful_turn_test() {
  use root <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(session_sup) = supervisor.start()
  let assert Ok(router) =
    telegram_router.start_with_session_supervisor(
      session_sup,
      mock_provider_config(),
    )
  complete_telegram_bootstrap(
    router,
    "chat-prd-self-state",
    "user-prd-self-state",
    "alice",
  )

  let turn =
    message(
      "tg-prd-self-state-1",
      "telegram",
      "chat-prd-self-state",
      "user-prd-self-state",
      "alice",
      "responda qualquer coisa",
      False,
    )
  let assert Ok(_) = telegram_router.route(router, turn)

  let assert Ok(serialized_state) =
    ffi_read_file(
      root <> "/telegram:user-prd-self-state/.supernova/SELF_STATE.json",
    )
  serialized_state
  |> string.contains("\"mood_cause\":\"turn_success\"")
  |> should.equal(True)
  serialized_state
  |> string.contains("\"valence\":0.0")
  |> should.equal(False)
}

pub fn discord_router_selected_model_survives_router_restart_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(session_sup) = supervisor.start()
  let assert Ok(router) =
    discord_router.start_with_session_supervisor(
      session_sup,
      mock_provider_config(),
    )
  let selection =
    interaction(
      "discord",
      "channel-persist",
      "user-persist",
      "bob",
      "picker_model_select",
      ["mock|mock-alt-model"],
    )

  let assert Ok(_) =
    discord_router.route_inbound(router, port.inbound_interaction(selection))

  let assert Ok(restarted_router) =
    discord_router.start_with_session_supervisor(
      session_sup,
      mock_provider_config(),
    )
  let status_msg =
    message(
      "dc-persist-1",
      "discord",
      "channel-persist",
      "user-persist",
      "bob",
      "/status",
      False,
    )

  case discord_router.route(restarted_router, status_msg) {
    Ok(reply) ->
      reply.content
      |> should.equal(
        "Session status: not started\n"
        <> "Agent: discord:user-persist\n"
        <> "Provider: Mock\n"
        <> "Model: mock-alt-model",
      )
    Error(_) -> should.fail()
  }

  let session_id = session.discord_session_id("channel-persist", "user-persist")
  let assert Ok(session) = supervisor.get_session(session_sup, session_id)
  server.get_model(session)
  |> should.equal(Some("mock-alt-model"))
}

pub fn discord_router_help_uses_channel_specific_text_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = discord_router.start(mock_provider_config())
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

pub fn discord_router_help_shortcut_alias_test() {
  use _ <- test_workspace.with_isolated_workspace("channel-router")
  let assert Ok(router) = discord_router.start(mock_provider_config())
  let help_msg =
    message(
      "dc-help-alias-1",
      "discord",
      "channel-help",
      "user-help",
      "bob",
      "ajuda",
      False,
    )

  case discord_router.route(router, help_msg) {
    Ok(reply) ->
      string.contains(reply.content, "Supernova AI Agent Framework")
      |> should.equal(True)
    Error(_) -> should.fail()
  }
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(String, String)
