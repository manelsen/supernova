import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/adapters/channel_common_router as router
import supernova/channel/port
import supernova/core/session/supervisor as session_supervisor
import supernova/llm/provider
import test_workspace

pub fn main() {
  gleeunit.main()
}

fn default_llm_config() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}

fn resolve_session_id(channel_id: String, user_id: String) -> String {
  channel_id <> ":" <> user_id
}

fn message(
  channel: String,
  channel_id: String,
  user_id: String,
  content: String,
  is_bot: Bool,
) -> port.ChannelMessage {
  port.ChannelMessage(
    id: "msg-" <> user_id,
    channel: channel,
    channel_id: channel_id,
    user_id: user_id,
    username: "user-" <> user_id,
    content: content,
    is_bot: is_bot,
    reply_to_id: None,
  )
}

fn interaction(
  channel: String,
  channel_id: String,
  user_id: String,
  action_id: String,
  values: List(String),
  source_message_id: option.Option(String),
  is_bot: Bool,
) -> port.ChannelInteractionMessage {
  port.ChannelInteractionMessage(
    channel: channel,
    channel_id: channel_id,
    user_id: user_id,
    username: "user-" <> user_id,
    is_bot: is_bot,
    event: port.ChannelInteractionEvent(
      id: "interaction-" <> user_id,
      action_id: action_id,
      values: values,
      source_message_id: source_message_id,
    ),
  )
}

pub fn new_interactive_state_starts_empty_test() {
  let state = router.new_interactive_state()
  dict.size(state.agent_choices) |> should.equal(0)
  dict.size(state.session_profiles) |> should.equal(0)
}

pub fn handle_inbound_start_and_status_commands_test() {
  use _ <- test_workspace.with_isolated_workspace("common-router")
  let cfg = default_llm_config()
  let state0 = router.new_interactive_state()
  let #(state1, start_result) =
    router.handle_inbound(
      "discord",
      port.inbound_message(message("discord", "c-10", "u-10", "/start", False)),
      cfg,
      state0,
      resolve_session_id,
    )

  case start_result {
    Ok(reply) ->
      string.contains(reply.content, "Session bootstrapped.")
      |> should.equal(True)
    Error(_) -> should.fail()
  }

  let #(_, status_result) =
    router.handle_inbound(
      "discord",
      port.inbound_message(message("discord", "c-10", "u-10", "/status", False)),
      cfg,
      state1,
      resolve_session_id,
    )

  case status_result {
    Ok(reply) -> {
      string.contains(reply.content, "Sessão: pronta")
      |> should.equal(True)
      string.contains(reply.content, "Provedor: Mock") |> should.equal(True)
      string.contains(reply.content, "Modelo: mock-model")
      |> should.equal(True)
    }
    Error(_) -> should.fail()
  }
}

pub fn handle_inbound_model_command_supported_and_fallback_channels_test() {
  use _ <- test_workspace.with_isolated_workspace("common-router")
  let cfg = default_llm_config()
  let state = router.new_interactive_state()

  let #(_, discord_result) =
    router.handle_inbound(
      "discord",
      port.inbound_message(message("discord", "c-20", "u-20", "/model", False)),
      cfg,
      state,
      resolve_session_id,
    )
  case discord_result {
    Ok(reply) ->
      case reply.interactive {
        Some(_) -> Nil
        None -> should.fail()
      }
    Error(_) -> should.fail()
  }

  let #(_, matrix_result) =
    router.handle_inbound(
      "matrix",
      port.inbound_message(message("matrix", "c-21", "u-21", "/model", False)),
      cfg,
      state,
      resolve_session_id,
    )
  case matrix_result {
    Ok(reply) ->
      string.contains(reply.content, "Para trocar: /model <modelo>")
      |> should.equal(True)
    Error(_) -> should.fail()
  }
}

pub fn handle_inbound_interaction_rejects_unsupported_channel_and_action_test() {
  use _ <- test_workspace.with_isolated_workspace("common-router")
  let cfg = default_llm_config()
  let state = router.new_interactive_state()

  let #(_, unsupported_channel_result) =
    router.handle_inbound(
      "matrix",
      port.inbound_interaction(interaction(
        "matrix",
        "c-50",
        "u-50",
        "picker_model_select",
        ["mock|mock-model"],
        None,
        False,
      )),
      cfg,
      state,
      resolve_session_id,
    )
  case unsupported_channel_result {
    Error(port.UnsupportedInteraction(reason)) ->
      string.contains(reason, "not supported for channel: matrix")
      |> should.equal(True)
    _ -> should.fail()
  }

  let #(_, unsupported_action_result) =
    router.handle_inbound(
      "discord",
      port.inbound_interaction(interaction(
        "discord",
        "c-51",
        "u-51",
        "unknown_action",
        [],
        None,
        False,
      )),
      cfg,
      state,
      resolve_session_id,
    )
  case unsupported_action_result {
    Error(port.UnsupportedInteraction(reason)) ->
      string.contains(reason, "Unsupported interaction action: unknown_action")
      |> should.equal(True)
    _ -> should.fail()
  }
}

pub fn handle_inbound_for_handler_returns_immediate_and_stream_results_test() {
  use _ <- test_workspace.with_isolated_workspace("common-router")
  let cfg = default_llm_config()
  let state0 = router.new_interactive_state()
  let stream_events = process.new_subject()

  let #(_, immediate_result) =
    router.handle_inbound_for_handler(
      "discord",
      port.inbound_message(message("discord", "c-60", "u-60", "/ping", False)),
      cfg,
      state0,
      resolve_session_id,
      stream_events,
    )
  case immediate_result {
    Ok(port.ImmediateReply(reply)) -> reply.content |> should.equal("pong")
    _ -> should.fail()
  }

  let #(_, stream_result) =
    router.handle_inbound_for_handler(
      "discord",
      port.inbound_message(message("discord", "c-61", "u-61", "hello", False)),
      cfg,
      state0,
      resolve_session_id,
      stream_events,
    )
  case stream_result {
    Ok(port.StreamReply(base_reply)) -> {
      base_reply.typing |> should.equal(True)
      base_reply.content |> should.equal("")
      drain_stream_until_done(stream_events)
    }
    _ -> should.fail()
  }
}

fn drain_stream_until_done(events: process.Subject(port.ChannelStreamEvent)) {
  case process.receive(events, within: 1000) {
    Ok(port.StreamUpdate(_)) -> drain_stream_until_done(events)
    Ok(port.StreamComplete(_)) -> process.sleep(20)
    Ok(port.StreamFailure(_)) -> process.sleep(20)
    Error(_) -> should.fail()
  }
}

pub fn handle_inbound_with_session_supervisor_wrappers_test() {
  use _ <- test_workspace.with_isolated_workspace("common-router")
  let assert Ok(supervisor) = session_supervisor.start()
  let cfg = default_llm_config()
  let state0 = router.new_interactive_state()
  let stream_events = process.new_subject()

  let #(state1, reply_result) =
    router.handle_inbound_with_session_supervisor(
      "discord",
      port.inbound_message(message("discord", "c-70", "u-70", "/status", False)),
      cfg,
      state0,
      resolve_session_id,
      supervisor,
    )
  case reply_result {
    Ok(reply) ->
      string.contains(reply.content, "Provedor:") |> should.equal(True)
    Error(_) -> should.fail()
  }

  let #(_, handler_result) =
    router.handle_inbound_with_session_supervisor_for_handler(
      "discord",
      port.inbound_message(message("discord", "c-70", "u-70", "/help", False)),
      cfg,
      state1,
      resolve_session_id,
      supervisor,
      stream_events,
    )
  case handler_result {
    Ok(port.ImmediateReply(reply)) ->
      string.contains(reply.content, "Supernova AI Agent Framework")
      |> should.equal(True)
    _ -> should.fail()
  }

  session_supervisor.stop(supervisor)
}

pub fn handle_inbound_ignores_bot_and_empty_message_test() {
  use _ <- test_workspace.with_isolated_workspace("common-router")
  let cfg = default_llm_config()
  let state = router.new_interactive_state()

  let #(_, bot_result) =
    router.handle_inbound(
      "discord",
      port.inbound_message(message("discord", "c-80", "u-80", "hello", True)),
      cfg,
      state,
      resolve_session_id,
    )
  bot_result |> should.equal(Error(port.Ignored(reason: "bot message")))

  let #(_, empty_result) =
    router.handle_inbound(
      "discord",
      port.inbound_message(message("discord", "c-81", "u-81", "", False)),
      cfg,
      state,
      resolve_session_id,
    )
  empty_result |> should.equal(Error(port.Ignored(reason: "empty content")))
}

pub fn handle_inbound_interaction_mismatch_and_bot_filters_test() {
  use _ <- test_workspace.with_isolated_workspace("common-router")
  let cfg = default_llm_config()
  let state = router.new_interactive_state()

  let #(_, mismatch_result) =
    router.handle_inbound(
      "discord",
      port.inbound_interaction(interaction(
        "telegram",
        "c-90",
        "u-90",
        "picker_model_select",
        ["mock|mock-model"],
        None,
        False,
      )),
      cfg,
      state,
      resolve_session_id,
    )
  mismatch_result
  |> should.equal(Error(port.Ignored(reason: "channel mismatch: telegram")))

  let #(_, bot_result) =
    router.handle_inbound(
      "discord",
      port.inbound_interaction(interaction(
        "discord",
        "c-91",
        "u-91",
        "picker_model_select",
        ["mock|mock-model"],
        None,
        True,
      )),
      cfg,
      state,
      resolve_session_id,
    )
  bot_result |> should.equal(Error(port.Ignored(reason: "bot message")))
}

pub fn handle_inbound_bootstrap_progression_with_reset_identity_test() {
  use _ <- test_workspace.with_isolated_workspace("common-router")
  let assert Ok(supervisor) = session_supervisor.start()
  let cfg = default_llm_config()
  let state0 = router.new_interactive_state()

  let #(state1, reset_result) =
    router.handle_inbound_with_session_supervisor(
      "discord",
      port.inbound_message(message(
        "discord",
        "c-100",
        "u-bootstrap-100",
        "/reset-identity",
        False,
      )),
      cfg,
      state0,
      resolve_session_id,
      supervisor,
    )
  case reset_result {
    Ok(reply) ->
      string.contains(reply.content, "Como você quer me chamar?")
      |> should.equal(True)
    Error(_) -> should.fail()
  }

  let #(state2, soul_question_result) =
    router.handle_inbound_with_session_supervisor(
      "discord",
      port.inbound_message(message(
        "discord",
        "c-100",
        "u-bootstrap-100",
        "Nova",
        False,
      )),
      cfg,
      state1,
      resolve_session_id,
      supervisor,
    )
  case soul_question_result {
    Ok(reply) ->
      string.contains(reply.content, "personalidade você quer")
      |> should.equal(True)
    Error(_) -> should.fail()
  }

  let #(state3, style_question_result) =
    router.handle_inbound_with_session_supervisor(
      "discord",
      port.inbound_message(message(
        "discord",
        "c-100",
        "u-bootstrap-100",
        "Técnica e direta",
        False,
      )),
      cfg,
      state2,
      resolve_session_id,
      supervisor,
    )
  case style_question_result {
    Ok(reply) ->
      string.contains(reply.content, "prefere que eu me comunique")
      |> should.equal(True)
    Error(_) -> should.fail()
  }

  let #(state4, user_question_result) =
    router.handle_inbound_with_session_supervisor(
      "discord",
      port.inbound_message(message(
        "discord",
        "c-100",
        "u-bootstrap-100",
        "Respostas curtas",
        False,
      )),
      cfg,
      state3,
      resolve_session_id,
      supervisor,
    )
  case user_question_result {
    Ok(reply) ->
      string.contains(reply.content, "devo te chamar") |> should.equal(True)
    Error(_) -> should.fail()
  }

  let #(state5, completed_result) =
    router.handle_inbound_with_session_supervisor(
      "discord",
      port.inbound_message(message(
        "discord",
        "c-100",
        "u-bootstrap-100",
        "Micelio",
        False,
      )),
      cfg,
      state4,
      resolve_session_id,
      supervisor,
    )
  case completed_result {
    Ok(reply) ->
      string.contains(reply.content, "Pronto! Sou Nova") |> should.equal(True)
    Error(_) -> should.fail()
  }

  let #(_, status_result) =
    router.handle_inbound_with_session_supervisor(
      "discord",
      port.inbound_message(message(
        "discord",
        "c-100",
        "u-bootstrap-100",
        "/status",
        False,
      )),
      cfg,
      state5,
      resolve_session_id,
      supervisor,
    )
  case status_result {
    Ok(reply) ->
      string.contains(reply.content, "Sessão: pronta")
      |> should.equal(True)
    Error(_) -> should.fail()
  }

  session_supervisor.stop(supervisor)
}

pub fn handle_inbound_can_skip_bootstrap_with_bracket_prefix_test() {
  use _ <- test_workspace.with_isolated_workspace("common-router")
  let assert Ok(supervisor) = session_supervisor.start()
  let cfg = default_llm_config()
  let state0 = router.new_interactive_state()

  let #(state1, _) =
    router.handle_inbound_with_session_supervisor(
      "discord",
      port.inbound_message(message(
        "discord",
        "c-101",
        "u-bootstrap-101",
        "/reset-identity",
        False,
      )),
      cfg,
      state0,
      resolve_session_id,
      supervisor,
    )

  let #(_, result) =
    router.handle_inbound_with_session_supervisor(
      "discord",
      port.inbound_message(message(
        "discord",
        "c-101",
        "u-bootstrap-101",
        "[skip-bootstrap]",
        False,
      )),
      cfg,
      state1,
      resolve_session_id,
      supervisor,
    )

  case result {
    Ok(reply) -> reply.content |> should.equal("Mock response")
    Error(_) -> should.fail()
  }

  session_supervisor.stop(supervisor)
}

pub fn handle_inbound_commands_and_reasoning_shortcuts_toggle_test() {
  use _ <- test_workspace.with_isolated_workspace("common-router")
  let cfg = default_llm_config()
  let state0 = router.new_interactive_state()

  let #(state1, commands_result) =
    router.handle_inbound(
      "telegram",
      port.inbound_message(message(
        "telegram",
        "c-110",
        "u-110",
        "commands",
        False,
      )),
      cfg,
      state0,
      resolve_session_id,
    )

  case commands_result {
    Ok(reply) ->
      string.contains(reply.content, "Available Commands")
      |> should.equal(True)
    Error(_) -> should.fail()
  }

  let #(state2, reasoning_on_result) =
    router.handle_inbound(
      "telegram",
      port.inbound_message(message(
        "telegram",
        "c-110",
        "u-110",
        "reasoning",
        False,
      )),
      cfg,
      state1,
      resolve_session_id,
    )

  case reasoning_on_result {
    Ok(reply) ->
      string.contains(reply.content, "Estado atual: on.")
      |> should.equal(True)
    Error(_) -> should.fail()
  }

  let #(_, reasoning_off_result) =
    router.handle_inbound(
      "telegram",
      port.inbound_message(message(
        "telegram",
        "c-110",
        "u-110",
        "reasoning",
        False,
      )),
      cfg,
      state2,
      resolve_session_id,
    )

  case reasoning_off_result {
    Ok(reply) ->
      string.contains(reply.content, "Estado atual: off.")
      |> should.equal(True)
    Error(_) -> should.fail()
  }
}

pub fn handle_inbound_models_alias_returns_interactive_for_slack_test() {
  use _ <- test_workspace.with_isolated_workspace("common-router")
  let cfg = default_llm_config()
  let state = router.new_interactive_state()

  let #(_, result) =
    router.handle_inbound(
      "slack",
      port.inbound_message(message("slack", "c-111", "u-111", "/models", False)),
      cfg,
      state,
      resolve_session_id,
    )

  case result {
    Ok(reply) -> {
      string.contains(reply.content, "Em uso: Mock / mock-model")
      |> should.equal(True)
      // One provider configured: no provider buttons, only its models.
      case reply.interactive {
        Some(interactive) ->
          interactive.blocks |> list.length |> should.equal(2)
        None -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn workspace_root_defaults_to_workspaces_and_respects_env_test() {
  let previous = test_workspace.get_workspace_root()
  test_workspace.reset_workspace_root()
  router.workspace_root() |> should.equal("workspaces")

  test_workspace.set_workspace_root("/tmp/custom-workspaces/")
  router.workspace_root() |> should.equal("/tmp/custom-workspaces")

  case previous {
    Ok(old) -> test_workspace.set_workspace_root(old)
    Error(_) -> test_workspace.reset_workspace_root()
  }
}
