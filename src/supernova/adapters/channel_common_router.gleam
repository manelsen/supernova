//// Shared router implementation for channel adapters using the port contract.
////
//// This module centralises the common adapter flow:
//// - channel validation
//// - bot/empty message filtering
//// - session lookup via provided callback
//// - executor dispatch
//// - standardized reply/error mapping

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port
import supernova/core/executor
import supernova/core/ux
import supernova/llm/provider
import supernova/llm/providers/minimax
import supernova/llm/providers/opencode_zen
import supernova/llm/providers/openrouter
import supernova/llm/providers/zhipu

/// Function to resolve/create a session id for an incoming message.
pub type ResolveSession =
  fn(port.ChannelMessage) -> String

/// Function to resolve/create a session id from channel and user identifiers.
pub type ResolveSessionFromParticipant =
  fn(String, String) -> String

/// Interactive router state scoped by session.
pub type InteractiveRouterState {
  InteractiveRouterState(
    session_configs: Dict(String, provider.ProviderConfig),
    session_profiles: Dict(String, SessionProfile),
  )
}

/// Per-session bootstrap profile used by channel flows.
pub type SessionProfile {
  SessionProfile(agent_id: String, bootstrapped: Bool)
}

/// Create a new empty interactive router state.
pub fn new_interactive_state() -> InteractiveRouterState {
  InteractiveRouterState(
    session_configs: dict.new(),
    session_profiles: dict.new(),
  )
}

/// Handle a normalized channel message through the shared core flow.
pub fn handle_message(
  expected_channel: String,
  msg: port.ChannelMessage,
  llm_config: provider.ProviderConfig,
  resolve_session: ResolveSession,
) -> Result(port.ChannelReply, port.ChannelError) {
  case msg.channel != expected_channel {
    True -> Error(port.Ignored(reason: "channel mismatch: " <> msg.channel))
    False -> {
      case msg.is_bot {
        True -> Error(port.Ignored(reason: "bot message"))
        False -> {
          case msg.content {
            "" -> Error(port.Ignored(reason: "empty content"))
            _ -> {
              let session_id = resolve_session(msg)
              case
                executor.run(
                  [provider.user_message(msg.content)],
                  llm_config,
                  executor.builtin_tools(),
                )
              {
                Ok(chat_response) ->
                  Ok(port.reply(
                    to: msg,
                    content: default_response(
                      msg.content,
                      session_id,
                      chat_response.content,
                    ),
                  ))
                Error(error) ->
                  Error(port.SendFailed(reason: format_executor_error(error)))
              }
            }
          }
        }
      }
    }
  }
}

/// Handle inbound messages and interaction callbacks through the shared flow.
pub fn handle_inbound(
  expected_channel: String,
  inbound: port.ChannelInbound,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
) -> #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)) {
  case inbound {
    port.InboundMessage(msg) ->
      handle_inbound_message(
        expected_channel,
        msg,
        default_llm_config,
        state,
        resolve_session,
      )
    port.InboundInteraction(interaction) ->
      handle_inbound_interaction(
        expected_channel,
        interaction,
        default_llm_config,
        state,
        resolve_session,
      )
  }
}

fn handle_inbound_message(
  expected_channel: String,
  msg: port.ChannelMessage,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
) -> #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)) {
  case msg.channel != expected_channel {
    True -> #(
      state,
      Error(port.Ignored(reason: "channel mismatch: " <> msg.channel)),
    )
    False -> {
      case msg.is_bot {
        True -> #(state, Error(port.Ignored(reason: "bot message")))
        False -> {
          case msg.content {
            "" -> #(state, Error(port.Ignored(reason: "empty content")))
            _ -> {
              let session_id = resolve_session(msg.channel_id, msg.user_id)
              let llm_config =
                session_config_for_session(
                  state,
                  session_id,
                  default_llm_config,
                )

              case bootstrap_command(msg.content) {
                Some(kind) ->
                  handle_bootstrap_command(
                    kind,
                    msg,
                    llm_config,
                    state,
                    session_id,
                  )
                None ->
                  case is_model_picker_command(msg.content) {
                    True -> {
                      let picker =
                        build_model_picker(llm_config, default_llm_config)
                      let content =
                        picker_intro(llm_config.name, llm_config.default_model)
                      case channel_supports_interactions(expected_channel) {
                        True -> #(
                          state,
                          Ok(port.reply_with_interactions(
                            to: msg,
                            content: content,
                            interactive: picker,
                          )),
                        )
                        False -> #(
                          state,
                          Ok(port.reply(
                            to: msg,
                            content: model_picker_fallback_text(
                              expected_channel,
                              llm_config,
                            ),
                          )),
                        )
                      }
                    }
                    False -> {
                      case
                        executor.run(
                          [provider.user_message(msg.content)],
                          llm_config,
                          executor.builtin_tools(),
                        )
                      {
                        Ok(chat_response) -> #(
                          state,
                          Ok(port.reply(
                            to: msg,
                            content: default_response(
                              msg.content,
                              session_id,
                              chat_response.content,
                            ),
                          )),
                        )
                        Error(error) -> #(
                          state,
                          Error(
                            port.SendFailed(reason: format_executor_error(error)),
                          ),
                        )
                      }
                    }
                  }
              }
            }
          }
        }
      }
    }
  }
}

fn handle_bootstrap_command(
  command: BootstrapCommand,
  msg: port.ChannelMessage,
  llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  session_id: String,
) -> #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)) {
  case command {
    StartCommand -> {
      let next_state = set_session_bootstrapped(state, session_id, msg.user_id)
      let profile =
        session_profile_for_session(next_state, session_id, msg.user_id)
      #(
        next_state,
        Ok(port.reply(
          to: msg,
          content: "Session bootstrapped.\nAgent: "
            <> profile.agent_id
            <> "\nModel: "
            <> llm_config.default_model,
        )),
      )
    }
    StatusCommand -> {
      let profile = session_profile_for_session(state, session_id, msg.user_id)
      let status = case profile.bootstrapped {
        True -> "ready"
        False -> "not started"
      }
      #(
        state,
        Ok(port.reply(
          to: msg,
          content: "Session status: "
            <> status
            <> "\nAgent: "
            <> profile.agent_id
            <> "\nProvider: "
            <> provider_display_name(llm_config.name)
            <> "\nModel: "
            <> llm_config.default_model,
        )),
      )
    }
    HelpCommand -> #(
      state,
      Ok(port.reply(to: msg, content: ux.help_text(msg.channel))),
    )
  }
}

fn set_session_bootstrapped(
  state: InteractiveRouterState,
  session_id: String,
  user_id: String,
) -> InteractiveRouterState {
  let current = session_profile_for_session(state, session_id, user_id)
  let next_profile = SessionProfile(..current, bootstrapped: True)
  put_session_profile(state, session_id, next_profile)
}

fn session_profile_for_session(
  state: InteractiveRouterState,
  session_id: String,
  user_id: String,
) -> SessionProfile {
  case dict.get(state.session_profiles, session_id) {
    Ok(profile) -> profile
    Error(_) ->
      SessionProfile(agent_id: default_agent_id(user_id), bootstrapped: False)
  }
}

fn put_session_profile(
  state: InteractiveRouterState,
  session_id: String,
  profile: SessionProfile,
) -> InteractiveRouterState {
  InteractiveRouterState(
    ..state,
    session_profiles: dict.insert(state.session_profiles, session_id, profile),
  )
}

fn default_agent_id(user_id: String) -> String {
  "agent:" <> user_id
}

type BootstrapCommand {
  StartCommand
  StatusCommand
  HelpCommand
}

fn bootstrap_command(content: String) -> Option(BootstrapCommand) {
  let command = string.trim(content) |> string.lowercase
  case command {
    "/start" -> Some(StartCommand)
    "/status" -> Some(StatusCommand)
    "/help" -> Some(HelpCommand)
    _ -> None
  }
}

fn handle_inbound_interaction(
  expected_channel: String,
  interaction: port.ChannelInteractionMessage,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
) -> #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)) {
  case interaction.channel != expected_channel {
    True -> #(
      state,
      Error(port.Ignored(reason: "channel mismatch: " <> interaction.channel)),
    )
    False -> {
      case interaction.is_bot {
        True -> #(state, Error(port.Ignored(reason: "bot message")))
        False -> {
          let session_id =
            resolve_session(interaction.channel_id, interaction.user_id)
          let active_config =
            session_config_for_session(state, session_id, default_llm_config)

          case channel_supports_interactions(expected_channel) {
            False -> #(
              state,
              Error(port.UnsupportedInteraction(
                reason: "Interactive callbacks not supported for channel: "
                <> expected_channel,
              )),
            )
            True ->
              case parse_provider_action(interaction.event.action_id) {
                Some(provider_name) -> {
                  case
                    is_supported_provider(
                      provider_name,
                      active_config.name,
                      default_llm_config.name,
                    )
                  {
                    True -> {
                      let next_config =
                        build_provider_config(provider_name, default_llm_config)
                      let next_state =
                        put_session_config(state, session_id, next_config)
                      let picker =
                        build_model_picker(next_config, default_llm_config)
                      let content =
                        "Provider set to "
                        <> provider_display_name(provider_name)
                        <> ". Select a model."

                      #(
                        next_state,
                        Ok(interaction_reply(interaction, content, Some(picker))),
                      )
                    }
                    False -> #(
                      state,
                      Error(port.UnsupportedInteraction(
                        reason: "Unknown provider selection: " <> provider_name,
                      )),
                    )
                  }
                }
                None ->
                  case interaction.event.action_id == "picker_model_select" {
                    True -> {
                      handle_model_selection(
                        interaction,
                        default_llm_config,
                        state,
                        session_id,
                        active_config,
                      )
                    }
                    False -> #(
                      state,
                      Error(port.UnsupportedInteraction(
                        reason: "Unsupported interaction action: "
                        <> interaction.event.action_id,
                      )),
                    )
                  }
              }
          }
        }
      }
    }
  }
}

fn handle_model_selection(
  interaction: port.ChannelInteractionMessage,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  session_id: String,
  active_config: provider.ProviderConfig,
) -> #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)) {
  case interaction.event.values {
    [selected_value, ..] -> {
      let #(provider_name, model_name) =
        decode_model_selection_value(selected_value, active_config.name)

      case
        is_supported_provider(
          provider_name,
          active_config.name,
          default_llm_config.name,
        )
      {
        True -> {
          let base_config = case provider_name == active_config.name {
            True -> active_config
            False -> build_provider_config(provider_name, default_llm_config)
          }
          let next_config =
            provider.ProviderConfig(..base_config, default_model: model_name)
          let next_state = put_session_config(state, session_id, next_config)
          let picker = build_model_picker(next_config, default_llm_config)
          let content = "Model set to " <> model_name <> " for this session."
          #(
            next_state,
            Ok(interaction_reply(interaction, content, Some(picker))),
          )
        }
        False -> #(
          state,
          Error(port.UnsupportedInteraction(
            reason: "Unknown provider in model selection: " <> provider_name,
          )),
        )
      }
    }
    [] -> #(
      state,
      Error(port.UnsupportedInteraction(
        reason: "Model selection interaction missing values",
      )),
    )
  }
}

fn interaction_reply(
  interaction: port.ChannelInteractionMessage,
  content: String,
  interactive: Option(port.ChannelInteractiveReply),
) -> port.ChannelReply {
  port.ChannelReply(
    channel_id: interaction.channel_id,
    content: content,
    reply_to_id: interaction.event.source_message_id,
    interactive: interactive,
  )
}

fn is_model_picker_command(content: String) -> Bool {
  let command = string.trim(content) |> string.lowercase
  command == "/model" || command == "/models"
}

fn picker_intro(provider_name: String, model_name: String) -> String {
  "Current selection: "
  <> provider_display_name(provider_name)
  <> " / "
  <> model_name
  <> "\nChoose provider and model for this session."
}

fn model_picker_fallback_text(
  channel: String,
  selected_config: provider.ProviderConfig,
) -> String {
  let models_summary =
    models_for_provider(selected_config.name, selected_config.default_model)
    |> list.take(5)
    |> string.join(", ")

  "Current selection: "
  <> provider_display_name(selected_config.name)
  <> " / "
  <> selected_config.default_model
  <> "\nInteractive picker is unavailable in "
  <> channel
  <> ". Available models for "
  <> provider_display_name(selected_config.name)
  <> ": "
  <> models_summary
}

fn channel_supports_interactions(channel: String) -> Bool {
  channel == "discord" || channel == "telegram"
}

fn parse_provider_action(action_id: String) -> Option(String) {
  let prefix = "picker_provider:"
  case string.starts_with(action_id, prefix) {
    True -> Some(string.drop_start(action_id, string.length(prefix)))
    False -> None
  }
}

fn decode_model_selection_value(
  value: String,
  fallback_provider: String,
) -> #(String, String) {
  case string.split(value, "|") {
    [provider_name, model_name] -> #(provider_name, model_name)
    _ -> #(fallback_provider, value)
  }
}

fn is_supported_provider(
  provider_name: String,
  selected_provider: String,
  default_provider: String,
) -> Bool {
  list.contains(
    provider_names(selected_provider, default_provider),
    provider_name,
  )
}

fn build_model_picker(
  selected_config: provider.ProviderConfig,
  default_llm_config: provider.ProviderConfig,
) -> port.ChannelInteractiveReply {
  let provider_buttons =
    provider_names(selected_config.name, default_llm_config.name)
    |> list.map(fn(name) {
      port.button(
        label: provider_display_name(name),
        action_id: "picker_provider:" <> name,
        style: provider_button_style(name, selected_config.name),
      )
    })

  let model_options =
    models_for_provider(selected_config.name, selected_config.default_model)
    |> list.map(fn(model_name) {
      port.select_option(
        label: model_label(model_name, selected_config.default_model),
        value: selected_config.name <> "|" <> model_name,
      )
    })

  port.interactive_reply([
    port.text_block("Provider: " <> provider_display_name(selected_config.name)),
    port.buttons_block(provider_buttons),
    port.select_block(
      action_id: "picker_model_select",
      placeholder: Some("Select model"),
      options: model_options,
    ),
  ])
}

fn model_label(model_name: String, selected_model: String) -> String {
  case model_name == selected_model {
    True -> "[active] " <> model_name
    False -> model_name
  }
}

fn provider_button_style(
  provider_name: String,
  selected_provider: String,
) -> port.ChannelButtonStyle {
  case provider_name == selected_provider {
    True -> port.ButtonSuccess
    False -> port.ButtonPrimary
  }
}

fn provider_display_name(provider_name: String) -> String {
  case provider_name {
    "openai" -> "OpenAI"
    "anthropic" -> "Anthropic"
    "openrouter" -> "OpenRouter"
    "opencode_zen" -> "OpenCode Zen"
    "zhipu" -> "Zhipu"
    "zhipu_coding" -> "Zhipu Coding"
    "minimax" -> "MiniMax"
    "mock" -> "Mock"
    _ -> provider_name
  }
}

fn known_provider_names() -> List(String) {
  [
    "openai",
    "anthropic",
    "openrouter",
    "opencode_zen",
    "zhipu",
    "zhipu_coding",
    "minimax",
    "mock",
  ]
}

fn provider_names(
  selected_provider: String,
  default_provider: String,
) -> List(String) {
  let with_default =
    ensure_provider_name(known_provider_names(), default_provider)
  let with_selected = ensure_provider_name(with_default, selected_provider)
  let rest = list.filter(with_selected, fn(name) { name != selected_provider })
  [selected_provider, ..rest]
}

fn ensure_provider_name(
  names: List(String),
  provider_name: String,
) -> List(String) {
  case list.contains(names, provider_name) {
    True -> names
    False -> [provider_name, ..names]
  }
}

fn models_for_provider(
  provider_name: String,
  selected_model: String,
) -> List(String) {
  let defaults = case provider_name {
    "openai" -> ["gpt-5-mini", "gpt-4.1", "gpt-4o"]
    "anthropic" -> ["claude-sonnet-4-5", "claude-haiku-4-5", "claude-opus-4-5"]
    "openrouter" -> [
      openrouter.default_model,
      "openai/gpt-4o",
      "anthropic/claude-opus-4-6",
    ]
    "opencode_zen" -> [opencode_zen.default_model, "glm-4.7", "kimi-k2"]
    "zhipu" -> [zhipu.default_model, "glm-4-air", "glm-4-flash"]
    "zhipu_coding" -> [zhipu.default_coding_model, "codegeex-4.6"]
    "minimax" -> [minimax.default_model, "abab6.5s-chat", "abab6.5g-chat"]
    "mock" -> ["mock-model", "mock-alt-model"]
    _ -> [selected_model]
  }

  let with_selected = case list.contains(defaults, selected_model) {
    True -> defaults
    False -> [selected_model, ..defaults]
  }

  list.take(with_selected, 25)
}

fn session_config_for_session(
  state: InteractiveRouterState,
  session_id: String,
  default_llm_config: provider.ProviderConfig,
) -> provider.ProviderConfig {
  case dict.get(state.session_configs, session_id) {
    Ok(config) -> config
    Error(_) -> default_llm_config
  }
}

fn put_session_config(
  state: InteractiveRouterState,
  session_id: String,
  llm_config: provider.ProviderConfig,
) -> InteractiveRouterState {
  InteractiveRouterState(
    ..state,
    session_configs: dict.insert(state.session_configs, session_id, llm_config),
  )
}

fn build_provider_config(
  provider_name: String,
  base_config: provider.ProviderConfig,
) -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: provider_name,
    api_key: base_config.api_key,
    base_url: base_config.base_url,
    default_model: default_model_for_provider(
      provider_name,
      base_config.default_model,
    ),
  )
}

fn default_model_for_provider(
  provider_name: String,
  fallback_model: String,
) -> String {
  case provider_name {
    "openai" -> "gpt-5-mini"
    "anthropic" -> "claude-sonnet-4-5"
    "openrouter" -> openrouter.default_model
    "opencode_zen" -> opencode_zen.default_model
    "zhipu" -> zhipu.default_model
    "zhipu_coding" -> zhipu.default_coding_model
    "minimax" -> minimax.default_model
    "mock" -> "mock-model"
    _ -> fallback_model
  }
}

fn default_response(
  original_content: String,
  session_id: String,
  model_content: String,
) -> String {
  case model_content {
    "" -> "Received: " <> original_content <> " (session: " <> session_id <> ")"
    content -> content
  }
}

fn format_executor_error(error: executor.ExecutorError) -> String {
  case error {
    executor.MaxDepthExceeded(depth) ->
      "Executor max depth exceeded: " <> int.to_string(depth)
    executor.LLMError(llm_error) -> "LLM error: " <> format_llm_error(llm_error)
    executor.ToolError(name, reason) ->
      "Tool error (" <> name <> "): " <> reason
    executor.YieldPaused(checkpoint_id) ->
      "Execution paused (checkpoint " <> checkpoint_id <> ")"
    executor.YieldAborted(reason) -> "Execution aborted: " <> reason
  }
}

fn format_llm_error(error: provider.LLMError) -> String {
  case error {
    provider.APIError(status, message) ->
      "API " <> int.to_string(status) <> " - " <> message
    provider.NetworkError(reason) -> "Network - " <> reason
    provider.ConfigError(reason) -> "Config - " <> reason
    provider.ProviderNotFound(name) -> "Provider not found: " <> name
    provider.NotImplemented(reason) -> "Not implemented: " <> reason
  }
}
