//// Shared router implementation for channel adapters using the port contract.
////
//// This module centralises the common adapter flow:
//// - channel validation
//// - bot/empty message filtering
//// - session lookup via provided callback
//// - executor dispatch
//// - standardized reply/error mapping

import envoy
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port
import supernova/config
import supernova/core/agent_identity
import supernova/core/audit_log/actor as audit_actor
import supernova/core/audit_log/types as audit_types
import supernova/core/closed_group/global as closed_group_global
import supernova/core/closed_group/pure as closed_group_pure
import supernova/core/closed_group/runtime as closed_group_runtime
import supernova/core/closed_group/types as closed_group_types
import supernova/core/error_ux
import supernova/core/exception_guard
import supernova/core/executor
import supernova/core/introspection/lesson
import supernova/core/introspection/mood
import supernova/core/introspection/relationship
import supernova/core/introspection/self_state
import supernova/core/persona/loader as persona_loader
import supernova/core/persona/types as persona_types
import supernova/core/prompt_assembly
import supernova/core/session/server as rich_session
import supernova/core/session/supervisor as session_supervisor
import supernova/core/ux
import supernova/llm/provider
import supernova/llm/providers/minimax
import supernova/llm/providers/opencode_zen
import supernova/llm/providers/openrouter
import supernova/llm/providers/zhipu
import supernova/llm/stream as llm_stream
import supernova/self/birth
import supernova/self/core as self_core

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
  SessionProfile(
    agent_id: String,
    bootstrapped: Bool,
    display_name: String,
    bootstrap_state: persona_types.BootstrapState,
    awaiting_bootstrap_answer: Bool,
    draft: persona_types.BootstrapDraft,
  )
}

/// Create a new empty interactive router state.
pub fn new_interactive_state() -> InteractiveRouterState {
  InteractiveRouterState(
    session_configs: dict.new(),
    session_profiles: dict.new(),
  )
}

/// Handle inbound messages and interaction callbacks through the shared flow.
pub fn handle_inbound(
  expected_channel: String,
  inbound: port.ChannelInbound,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
) -> #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)) {
  handle_inbound_internal(
    expected_channel,
    inbound,
    default_llm_config,
    state,
    resolve_session,
    None,
  )
}

/// Handle inbound messages and interaction callbacks for the runtime handler.
///
/// Normal chat turns may return a `port.StreamReply` so the registry can
/// progressively send/edit the response in the channel runtime.
pub fn handle_inbound_for_handler(
  expected_channel: String,
  inbound: port.ChannelInbound,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
  stream_events: process.Subject(port.ChannelStreamEvent),
) -> #(
  InteractiveRouterState,
  Result(port.ChannelHandlerResult, port.ChannelError),
) {
  handle_inbound_internal_for_handler(
    expected_channel,
    inbound,
    default_llm_config,
    state,
    resolve_session,
    None,
    stream_events,
  )
}

/// Handle inbound messages and interaction callbacks using a supervisor-backed
/// rich session trail for persisted history and model selection.
pub fn handle_inbound_with_session_supervisor(
  expected_channel: String,
  inbound: port.ChannelInbound,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
  supervisor: session_supervisor.SessionSupervisor,
) -> #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)) {
  handle_inbound_internal(
    expected_channel,
    inbound,
    default_llm_config,
    state,
    resolve_session,
    Some(supervisor),
  )
}

/// Handle inbound messages and interaction callbacks for the runtime handler
/// using a supervisor-backed rich session trail.
pub fn handle_inbound_with_session_supervisor_for_handler(
  expected_channel: String,
  inbound: port.ChannelInbound,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
  supervisor: session_supervisor.SessionSupervisor,
  stream_events: process.Subject(port.ChannelStreamEvent),
) -> #(
  InteractiveRouterState,
  Result(port.ChannelHandlerResult, port.ChannelError),
) {
  handle_inbound_internal_for_handler(
    expected_channel,
    inbound,
    default_llm_config,
    state,
    resolve_session,
    Some(supervisor),
    stream_events,
  )
}

fn handle_inbound_internal(
  expected_channel: String,
  inbound: port.ChannelInbound,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
  supervisor: Option(session_supervisor.SessionSupervisor),
) -> #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)) {
  case inbound {
    port.InboundMessage(msg) ->
      handle_inbound_message(
        expected_channel,
        msg,
        default_llm_config,
        state,
        resolve_session,
        supervisor,
      )
    port.InboundInteraction(interaction) ->
      handle_inbound_interaction(
        expected_channel,
        interaction,
        default_llm_config,
        state,
        resolve_session,
        supervisor,
      )
  }
}

fn handle_inbound_internal_for_handler(
  expected_channel: String,
  inbound: port.ChannelInbound,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
  supervisor: Option(session_supervisor.SessionSupervisor),
  stream_events: process.Subject(port.ChannelStreamEvent),
) -> #(
  InteractiveRouterState,
  Result(port.ChannelHandlerResult, port.ChannelError),
) {
  case inbound {
    port.InboundMessage(msg) ->
      handle_inbound_message_for_handler(
        expected_channel,
        msg,
        default_llm_config,
        state,
        resolve_session,
        supervisor,
        stream_events,
      )
    port.InboundInteraction(interaction) -> {
      let #(next_state, result) =
        handle_inbound_interaction(
          expected_channel,
          interaction,
          default_llm_config,
          state,
          resolve_session,
          supervisor,
        )

      #(next_state, map_reply_result_to_handler(result))
    }
  }
}

fn closed_group_gate(
  msg: port.ChannelMessage,
) -> Option(closed_group_types.GateResult) {
  closed_group_gate_for(msg.channel, msg.channel_id, msg.user_id, msg.content)
}

fn closed_group_gate_for(
  channel: String,
  channel_id: String,
  user_id: String,
  content: String,
) -> Option(closed_group_types.GateResult) {
  case closed_group_global.get_runtime() {
    None ->
      case closed_group_global.is_enforced() {
        True ->
          Some(closed_group_types.Reply(closed_group_pure.fail_closed_reply))
        False -> None
      }
    Some(runtime) ->
      Some(closed_group_runtime.gate(
        runtime,
        channel,
        channel_id,
        user_id,
        content,
      ))
  }
}

fn run_executor_for_context(
  messages: List(provider.ChatMessage),
  llm_config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
  context: Option(closed_group_types.PrincipalContext),
) -> Result(provider.ChatResponse, executor.ExecutorError) {
  case context, closed_group_global.get_runtime() {
    Some(turn), Some(runtime) -> {
      let filtered = closed_group_runtime.tools_for(runtime, turn.role, tools)
      executor.run_with_context(
        messages,
        llm_config,
        filtered,
        closed_group_runtime.run_context(runtime, turn),
      )
    }
    _, _ -> executor.run(messages, llm_config, tools)
  }
}

fn handle_inbound_message_for_handler(
  expected_channel: String,
  msg: port.ChannelMessage,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
  supervisor: Option(session_supervisor.SessionSupervisor),
  stream_events: process.Subject(port.ChannelStreamEvent),
) -> #(
  InteractiveRouterState,
  Result(port.ChannelHandlerResult, port.ChannelError),
) {
  case closed_group_gate(msg) {
    None ->
      handle_inbound_message_allowed_for_handler(
        expected_channel,
        msg,
        default_llm_config,
        state,
        resolve_session,
        supervisor,
        stream_events,
        None,
      )
    Some(closed_group_types.Allowed(context)) ->
      handle_inbound_message_allowed_for_handler(
        expected_channel,
        msg,
        default_llm_config,
        state,
        resolve_session,
        supervisor,
        stream_events,
        Some(context),
      )
    Some(closed_group_types.Reply(content)) -> #(
      state,
      Ok(port.ImmediateReply(port.reply(to: msg, content: content))),
    )
    Some(closed_group_types.Ignored(reason)) -> #(
      state,
      Error(port.Ignored(reason: reason)),
    )
  }
}

fn handle_inbound_message_allowed_for_handler(
  expected_channel: String,
  msg: port.ChannelMessage,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
  supervisor: Option(session_supervisor.SessionSupervisor),
  stream_events: process.Subject(port.ChannelStreamEvent),
  context: Option(closed_group_types.PrincipalContext),
) -> #(
  InteractiveRouterState,
  Result(port.ChannelHandlerResult, port.ChannelError),
) {
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
              let rich_session = ensure_rich_session(supervisor, session_id)
              let #(state_with_profile, profile) =
                ensure_profile_for_turn(
                  state,
                  session_id,
                  msg.user_id,
                  rich_session,
                )
              let llm_config =
                session_config_for_session(
                  state_with_profile,
                  session_id,
                  default_llm_config,
                  rich_session,
                )

              case maybe_handle_birth(msg, llm_config, context) {
                Some(reply) -> #(
                  state_with_profile,
                  Ok(port.ImmediateReply(reply)),
                )
                None ->
                  case bootstrap_command(msg.content) {
                    Some(kind) ->
                      case
                        closed_group_identity_frozen(profile.agent_id),
                        kind
                      {
                        True, StartCommand | True, ResetIdentityCommand -> #(
                          state_with_profile,
                          Ok(
                            port.ImmediateReply(port.reply(
                              to: msg,
                              content: "O núcleo desta agente é permanente; o dono só pode dar o nome.",
                            )),
                          ),
                        )
                        _, _ -> {
                          let #(next_state, result) =
                            handle_bootstrap_command(
                              kind,
                              msg,
                              llm_config,
                              state_with_profile,
                              session_id,
                            )

                          #(next_state, map_reply_result_to_handler(result))
                        }
                      }
                    None ->
                      case is_model_picker_command(msg.content) {
                        True -> {
                          let picker =
                            build_model_picker(llm_config, default_llm_config)
                          let content =
                            picker_intro(
                              llm_config.name,
                              llm_config.default_model,
                            )
                          case channel_supports_interactions(expected_channel) {
                            True -> #(
                              state_with_profile,
                              Ok(
                                port.ImmediateReply(
                                  port.reply_with_interactions(
                                    to: msg,
                                    content: content,
                                    interactive: picker,
                                  ),
                                ),
                              ),
                            )
                            False -> #(
                              state_with_profile,
                              Ok(
                                port.ImmediateReply(port.reply(
                                  to: msg,
                                  content: model_picker_fallback_text(
                                    expected_channel,
                                    llm_config,
                                  ),
                                )),
                              ),
                            )
                          }
                        }
                        False ->
                          case
                            maybe_handle_legacy_bootstrap(
                              msg,
                              state_with_profile,
                              session_id,
                              profile,
                              rich_session,
                            )
                          {
                            Some(#(next_state, result)) -> #(
                              next_state,
                              map_reply_result_to_handler(result),
                            )
                            None -> #(
                              state_with_profile,
                              Ok(start_streamed_message_reply(
                                msg,
                                session_id,
                                llm_config,
                                rich_session,
                                stream_events,
                                profile,
                                context,
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
    }
  }
}

fn handle_inbound_message(
  expected_channel: String,
  msg: port.ChannelMessage,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
  supervisor: Option(session_supervisor.SessionSupervisor),
) -> #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)) {
  case closed_group_gate(msg) {
    None ->
      handle_inbound_message_allowed(
        expected_channel,
        msg,
        default_llm_config,
        state,
        resolve_session,
        supervisor,
        None,
      )
    Some(closed_group_types.Allowed(context)) ->
      handle_inbound_message_allowed(
        expected_channel,
        msg,
        default_llm_config,
        state,
        resolve_session,
        supervisor,
        Some(context),
      )
    Some(closed_group_types.Reply(content)) -> #(
      state,
      Ok(port.reply(to: msg, content: content)),
    )
    Some(closed_group_types.Ignored(reason)) -> #(
      state,
      Error(port.Ignored(reason: reason)),
    )
  }
}

fn handle_inbound_message_allowed(
  expected_channel: String,
  msg: port.ChannelMessage,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
  supervisor: Option(session_supervisor.SessionSupervisor),
  context: Option(closed_group_types.PrincipalContext),
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
              let rich_session = ensure_rich_session(supervisor, session_id)
              let #(state_with_profile, profile) =
                ensure_profile_for_turn(
                  state,
                  session_id,
                  msg.user_id,
                  rich_session,
                )
              let llm_config =
                session_config_for_session(
                  state_with_profile,
                  session_id,
                  default_llm_config,
                  rich_session,
                )

              case bootstrap_command(msg.content) {
                Some(kind) ->
                  handle_bootstrap_command(
                    kind,
                    msg,
                    llm_config,
                    state_with_profile,
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
                          state_with_profile,
                          Ok(port.reply_with_interactions(
                            to: msg,
                            content: content,
                            interactive: picker,
                          )),
                        )
                        False -> #(
                          state_with_profile,
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
                    False ->
                      case
                        maybe_handle_legacy_bootstrap(
                          msg,
                          state_with_profile,
                          session_id,
                          profile,
                          rich_session,
                        )
                      {
                        Some(result) -> result
                        None -> {
                          let messages =
                            executor_messages_for_turn(
                              rich_session,
                              msg.content,
                              profile,
                            )
                          case
                            run_executor_for_context(
                              messages,
                              llm_config,
                              executor.builtin_tools(),
                              context,
                            )
                          {
                            Ok(chat_response) -> {
                              record_session_turn(
                                rich_session,
                                msg.content,
                                chat_response.content,
                              )
                              apply_success_self_state(
                                profile,
                                session_id,
                                msg.content,
                                chat_response.content,
                              )
                              #(
                                state_with_profile,
                                Ok(port.reply(
                                  to: msg,
                                  content: default_response(
                                    msg.content,
                                    session_id,
                                    chat_response.content,
                                  ),
                                )),
                              )
                            }
                            Error(error) -> #(state_with_profile, {
                              apply_error_self_state(
                                profile,
                                session_id,
                                msg.content,
                                error,
                              )
                              Error(
                                port.SendFailed(reason: error_ux.friendly(error)),
                              )
                            })
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
    CommandsCommand -> #(
      state,
      Ok(port.reply(to: msg, content: ux.commands_text(msg.channel))),
    )
    ReasoningCommand -> {
      let profile = session_profile_for_session(state, session_id, msg.user_id)
      let enabled = toggle_reasoning_preference(profile, True)
      let status = case enabled {
        True -> "on"
        False -> "off"
      }
      #(
        state,
        Ok(port.reply(
          to: msg,
          content: ux.reasoning_text() <> "\n\nEstado atual: " <> status <> ".",
        )),
      )
    }
    PingCommand -> #(state, Ok(port.reply(to: msg, content: "pong")))
    ResetIdentityCommand -> {
      let current = session_profile_for_session(state, session_id, msg.user_id)
      let next_profile =
        SessionProfile(
          ..current,
          bootstrapped: False,
          display_name: "",
          bootstrap_state: persona_types.AskingName,
          awaiting_bootstrap_answer: True,
          draft: persona_types.BootstrapDraft(
            name: None,
            soul: None,
            style: None,
          ),
        )
      let next_state = put_session_profile(state, session_id, next_profile)
      #(
        next_state,
        Ok(port.reply(
          to: msg,
          content: bootstrap_question(persona_types.AskingName),
        )),
      )
    }
  }
}

fn set_session_bootstrapped(
  state: InteractiveRouterState,
  session_id: String,
  user_id: String,
) -> InteractiveRouterState {
  let current = session_profile_for_session(state, session_id, user_id)
  let next_profile =
    SessionProfile(
      ..current,
      bootstrapped: True,
      bootstrap_state: persona_types.Complete,
      awaiting_bootstrap_answer: False,
    )
  put_session_profile(state, session_id, next_profile)
}

fn session_profile_for_session(
  state: InteractiveRouterState,
  session_id: String,
  _user_id: String,
) -> SessionProfile {
  case dict.get(state.session_profiles, session_id) {
    Ok(profile) -> profile
    Error(_) ->
      SessionProfile(
        agent_id: agent_identity.principal_from_session_id(session_id),
        bootstrapped: False,
        display_name: "",
        bootstrap_state: persona_types.AskingName,
        awaiting_bootstrap_answer: False,
        draft: persona_types.BootstrapDraft(name: None, soul: None, style: None),
      )
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

/// Resolve the base directory used for agent workspaces.
/// Defaults to `"workspaces"` unless `SUPERNOVA_WORKSPACE_ROOT` is configured.
pub fn workspace_root() -> String {
  case envoy.get("SUPERNOVA_WORKSPACE_ROOT") {
    Ok(root) ->
      case string.trim(root) {
        "" -> "workspaces"
        trimmed -> strip_trailing_slashes(trimmed)
      }
    Error(_) -> "workspaces"
  }
}

fn strip_trailing_slashes(path: String) -> String {
  case path != "/" && string.ends_with(path, "/") {
    True -> strip_trailing_slashes(string.drop_end(path, 1))
    False -> path
  }
}

fn workspace_path_for_agent(agent_id: String) -> String {
  case closed_group_global.get_config() {
    Some(cfg) ->
      case cfg.access.mode {
        config.Allowlist -> agent_identity.workspace_dir(cfg.data_dir, agent_id)
        config.Open -> workspace_root() <> "/" <> agent_id
      }
    None -> workspace_root() <> "/" <> agent_id
  }
}

fn sync_session_profile_from_workspace(
  profile: SessionProfile,
) -> SessionProfile {
  let workspace_path = workspace_path_for_agent(profile.agent_id)
  case persona_loader.load(workspace_path) {
    Ok(persona) ->
      SessionProfile(
        ..profile,
        bootstrapped: True,
        display_name: persona_loader.extract_name(persona.identity),
        bootstrap_state: persona_types.Complete,
        awaiting_bootstrap_answer: False,
      )
    Error(persona_types.BootstrapRequired) -> profile
    Error(_) -> profile
  }
}

fn ensure_profile_for_turn(
  state: InteractiveRouterState,
  session_id: String,
  user_id: String,
  rich_session: Option(rich_session.Session),
) -> #(InteractiveRouterState, SessionProfile) {
  let profile = session_profile_for_session(state, session_id, user_id)
  case rich_session {
    None -> #(state, profile)
    Some(_) -> {
      case profile.awaiting_bootstrap_answer {
        True -> #(state, profile)
        False -> {
          let synced = sync_session_profile_from_workspace(profile)
          #(put_session_profile(state, session_id, synced), synced)
        }
      }
    }
  }
}

fn is_bootstrap_pending(
  profile: SessionProfile,
  rich_session: Option(rich_session.Session),
) -> Bool {
  case rich_session {
    None -> False
    Some(_) -> !profile.bootstrapped
  }
}

fn bootstrap_question(state: persona_types.BootstrapState) -> String {
  case state {
    persona_types.AskingName ->
      "Olá! Sou um novo agente. Como você quer me chamar?"
    persona_types.AskingSoul ->
      "Que tipo de personalidade você quer que eu tenha? Pode ser livre — formal, irreverente, técnico, filosófico, qualquer coisa."
    persona_types.AskingStyle ->
      "Como prefere que eu me comunique? Por exemplo: respostas curtas, em português, sem emojis — ou qualquer estilo que funcione pra você."
    persona_types.AskingUser ->
      "E como devo te chamar? Pode me contar um pouco sobre você se quiser."
    persona_types.Complete -> "Bootstrap já concluído."
  }
}

fn default_bootstrap_value(state: persona_types.BootstrapState) -> String {
  case state {
    persona_types.AskingName -> "Nova"
    persona_types.AskingSoul -> "Técnica, honesta e colaborativa."
    persona_types.AskingStyle -> "Respostas curtas em português brasileiro."
    persona_types.AskingUser -> "Usuário sem preferências explícitas."
    persona_types.Complete -> ""
  }
}

fn timestamp_text() -> String {
  int.to_string(ffi_current_timestamp())
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

fn answer_or_default(
  content: String,
  state: persona_types.BootstrapState,
) -> String {
  let trimmed = string.trim(content)
  case trimmed {
    "" -> default_bootstrap_value(state)
    _ -> trimmed
  }
}

fn should_skip_bootstrap(content: String) -> Bool {
  string.starts_with(string.trim(content), "[")
}

fn closed_group_identity_frozen(agent_id: String) -> Bool {
  case closed_group_global.get_config() {
    Some(cfg) ->
      case self_core.load(cfg.data_dir, agent_id) {
        Some(core) ->
          case core.name {
            Some(_) -> True
            None -> False
          }
        None -> False
      }
    None -> False
  }
}

fn maybe_handle_legacy_bootstrap(
  msg: port.ChannelMessage,
  state: InteractiveRouterState,
  session_id: String,
  profile: SessionProfile,
  rich_session: Option(rich_session.Session),
) -> Option(
  #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)),
) {
  case closed_group_identity_frozen(profile.agent_id) {
    True -> None
    False ->
      maybe_handle_identity_bootstrap(
        msg,
        state,
        session_id,
        profile,
        rich_session,
      )
  }
}

fn maybe_handle_birth(
  msg: port.ChannelMessage,
  llm_config: provider.ProviderConfig,
  context: Option(closed_group_types.PrincipalContext),
) -> Option(port.ChannelReply) {
  case closed_group_global.get_config(), context {
    Some(cfg), Some(_) ->
      case cfg.access.mode {
        config.Allowlist -> {
          let principal_id = msg.channel <> ":" <> msg.user_id
          let generate = fn(prompt: String) {
            case
              run_executor_for_context(
                [provider.user_message(prompt)],
                llm_config,
                [],
                context,
              )
            {
              Ok(response) -> Ok(response.content)
              Error(_) -> Error("birth generation failed")
            }
          }
          let step =
            birth.step(
              cfg.data_dir,
              principal_id,
              msg.content,
              closed_group_global.now(),
              generate,
            )
          case step {
            birth.AskName(text) -> Some(port.reply(to: msg, content: text))
            birth.NameAccepted(name) ->
              Some(port.reply(to: msg, content: "Prazer, " <> name <> "."))
            birth.Unavailable -> {
              audit_birth_unavailable(principal_id)
              Some(port.reply(
                to: msg,
                content: "A Supernova ainda não está pronta para receber agentes novas.",
              ))
            }
            birth.BirthFailed ->
              Some(port.reply(
                to: msg,
                content: "Não consegui nascer agora. Tente de novo.",
              ))
            birth.AlreadyBorn -> None
          }
        }
        config.Open -> None
      }
    _, _ -> None
  }
}

fn audit_birth_unavailable(principal_id: String) -> Nil {
  case closed_group_global.get_audit() {
    Some(audit) ->
      audit_actor.log_entry(
        audit,
        audit_types.AuditEntry(
          timestamp: closed_group_global.now(),
          agent_id: principal_id,
          operation: "birth_unavailable",
          target: "constellation",
          result: audit_types.AuditFailure,
          details: "missing constellation or birth prompt",
        ),
      )
    None -> Nil
  }
}

fn maybe_handle_identity_bootstrap(
  msg: port.ChannelMessage,
  state: InteractiveRouterState,
  session_id: String,
  profile: SessionProfile,
  rich_session: Option(rich_session.Session),
) -> Option(
  #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)),
) {
  case should_skip_bootstrap(msg.content) {
    True -> None
    False -> {
      case is_bootstrap_pending(profile, rich_session) {
        False -> None
        True ->
          case profile.awaiting_bootstrap_answer {
            False -> {
              let next_profile =
                SessionProfile(..profile, awaiting_bootstrap_answer: True)
              let next_state =
                put_session_profile(state, session_id, next_profile)
              Some(#(
                next_state,
                Ok(port.reply(
                  to: msg,
                  content: bootstrap_question(profile.bootstrap_state),
                )),
              ))
            }
            True -> {
              let answer =
                answer_or_default(msg.content, profile.bootstrap_state)
              case profile.bootstrap_state {
                persona_types.AskingName -> {
                  let next_profile =
                    SessionProfile(
                      ..profile,
                      draft: persona_types.BootstrapDraft(
                        ..profile.draft,
                        name: Some(answer),
                      ),
                      bootstrap_state: persona_types.AskingSoul,
                    )
                  let next_state =
                    put_session_profile(state, session_id, next_profile)
                  Some(#(
                    next_state,
                    Ok(port.reply(
                      to: msg,
                      content: bootstrap_question(persona_types.AskingSoul),
                    )),
                  ))
                }
                persona_types.AskingSoul -> {
                  let next_profile =
                    SessionProfile(
                      ..profile,
                      draft: persona_types.BootstrapDraft(
                        ..profile.draft,
                        soul: Some(answer),
                      ),
                      bootstrap_state: persona_types.AskingStyle,
                    )
                  let next_state =
                    put_session_profile(state, session_id, next_profile)
                  Some(#(
                    next_state,
                    Ok(port.reply(
                      to: msg,
                      content: bootstrap_question(persona_types.AskingStyle),
                    )),
                  ))
                }
                persona_types.AskingStyle -> {
                  let next_profile =
                    SessionProfile(
                      ..profile,
                      draft: persona_types.BootstrapDraft(
                        ..profile.draft,
                        style: Some(answer),
                      ),
                      bootstrap_state: persona_types.AskingUser,
                    )
                  let next_state =
                    put_session_profile(state, session_id, next_profile)
                  Some(#(
                    next_state,
                    Ok(port.reply(
                      to: msg,
                      content: bootstrap_question(persona_types.AskingUser),
                    )),
                  ))
                }
                persona_types.AskingUser -> {
                  let name = case profile.draft.name {
                    Some(value) -> value
                    None -> default_bootstrap_value(persona_types.AskingName)
                  }
                  let soul = case profile.draft.soul {
                    Some(value) -> value
                    None -> default_bootstrap_value(persona_types.AskingSoul)
                  }
                  let style = case profile.draft.style {
                    Some(value) -> value
                    None -> default_bootstrap_value(persona_types.AskingStyle)
                  }
                  let workspace_path =
                    workspace_path_for_agent(profile.agent_id)
                  case
                    persona_loader.write_bootstrap_files(
                      workspace_path,
                      name: name,
                      soul: soul,
                      style: style,
                      user: answer,
                      timestamp: timestamp_text(),
                    )
                  {
                    Ok(persona) -> {
                      let display_name =
                        persona_loader.extract_name(persona.identity)
                      let _ =
                        self_state.save(workspace_path, self_state.default())
                      let next_profile =
                        SessionProfile(
                          ..profile,
                          bootstrapped: True,
                          display_name: display_name,
                          bootstrap_state: persona_types.Complete,
                          awaiting_bootstrap_answer: False,
                          draft: persona_types.BootstrapDraft(
                            name: None,
                            soul: None,
                            style: None,
                          ),
                        )
                      let next_state =
                        put_session_profile(state, session_id, next_profile)
                      Some(#(
                        next_state,
                        Ok(port.reply(
                          to: msg,
                          content: "Pronto! Sou "
                            <> display_name
                            <> " agora. Como posso ajudar?",
                        )),
                      ))
                    }
                    Error(reason) ->
                      Some(#(
                        state,
                        Error(port.SendFailed(
                          reason: "Falha ao salvar identidade: "
                          <> bootstrap_error_text(reason),
                        )),
                      ))
                  }
                }
                persona_types.Complete -> None
              }
            }
          }
      }
    }
  }
}

fn bootstrap_error_text(reason: persona_types.LoadError) -> String {
  case reason {
    persona_types.BootstrapRequired -> "bootstrap_required"
    persona_types.ReadFailed(path, detail) ->
      "read_failed(" <> path <> "): " <> detail
    persona_types.WriteFailed(path, detail) ->
      "write_failed(" <> path <> "): " <> detail
    persona_types.EnsureDirFailed(path, detail) ->
      "ensure_dir_failed(" <> path <> "): " <> detail
  }
}

type BootstrapCommand {
  StartCommand
  StatusCommand
  HelpCommand
  CommandsCommand
  ReasoningCommand
  PingCommand
  ResetIdentityCommand
}

fn bootstrap_command(content: String) -> Option(BootstrapCommand) {
  case ux.resolve_shortcut(content) {
    Ok(ux.NewSession) -> Some(StartCommand)
    Ok(ux.Status) -> Some(StatusCommand)
    Ok(ux.Help) -> Some(HelpCommand)
    Ok(ux.Menu) -> Some(CommandsCommand)
    Ok(ux.Think) -> Some(ReasoningCommand)
    Ok(ux.Ping) -> Some(PingCommand)
    Ok(ux.ResetIdentity) -> Some(ResetIdentityCommand)
    _ -> {
      let command = string.trim(content) |> string.lowercase
      case command {
        "/commands" -> Some(CommandsCommand)
        "/reset-identity" -> Some(ResetIdentityCommand)
        _ -> None
      }
    }
  }
}

fn closed_group_gate_interaction(
  interaction: port.ChannelInteractionMessage,
) -> Option(closed_group_types.GateResult) {
  case closed_group_global.get_runtime() {
    None ->
      case closed_group_global.is_enforced() {
        True ->
          Some(closed_group_types.Reply(closed_group_pure.fail_closed_reply))
        False -> None
      }
    Some(runtime) ->
      Some(closed_group_runtime.gate_interaction(
        runtime,
        interaction.channel,
        interaction.channel_id,
        interaction.user_id,
      ))
  }
}

fn interaction_denial_reply(
  interaction: port.ChannelInteractionMessage,
  content: String,
) -> port.ChannelReply {
  port.ChannelReply(
    channel_id: interaction.channel_id,
    content: content,
    reply_to_id: interaction.event.source_message_id,
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: None,
    media: [],
  )
}

fn handle_inbound_interaction(
  expected_channel: String,
  interaction: port.ChannelInteractionMessage,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
  supervisor: Option(session_supervisor.SessionSupervisor),
) -> #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)) {
  case interaction.channel != expected_channel {
    True -> #(
      state,
      Error(port.Ignored(reason: "channel mismatch: " <> interaction.channel)),
    )
    False -> {
      case interaction.is_bot {
        True -> #(state, Error(port.Ignored(reason: "bot message")))
        False ->
          // Callbacks change session provider/model and persist preferences,
          // so they pass the same access gate as messages. The content is
          // empty: no command is dispatched from a button click.
          case closed_group_gate_interaction(interaction) {
            Some(closed_group_types.Reply(content)) -> #(
              state,
              Ok(interaction_denial_reply(interaction, content)),
            )
            Some(closed_group_types.Ignored(reason)) -> #(
              state,
              Error(port.Ignored(reason: reason)),
            )
            Some(closed_group_types.Allowed(_)) | None ->
              handle_allowed_interaction(
                expected_channel,
                interaction,
                default_llm_config,
                state,
                resolve_session,
                supervisor,
              )
          }
      }
    }
  }
}

fn handle_allowed_interaction(
  expected_channel: String,
  interaction: port.ChannelInteractionMessage,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  resolve_session: ResolveSessionFromParticipant,
  supervisor: Option(session_supervisor.SessionSupervisor),
) -> #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)) {
  let session_id = resolve_session(interaction.channel_id, interaction.user_id)
  let rich_session = ensure_rich_session(supervisor, session_id)
  let active_config =
    session_config_for_session(
      state,
      session_id,
      default_llm_config,
      rich_session,
    )

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
              persist_session_llm_config(rich_session, next_config)
              persist_model_preference_for_user(
                state,
                session_id,
                interaction.user_id,
                next_config.default_model,
              )
              let next_state =
                put_session_config(state, session_id, next_config)
              let picker = build_model_picker(next_config, default_llm_config)
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
                rich_session,
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

fn handle_model_selection(
  interaction: port.ChannelInteractionMessage,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  session_id: String,
  active_config: provider.ProviderConfig,
  rich_session: Option(rich_session.Session),
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
          persist_session_llm_config(rich_session, next_config)
          persist_model_preference_for_user(
            state,
            session_id,
            interaction.user_id,
            next_config.default_model,
          )
          let next_state = put_session_config(state, session_id, next_config)
          let picker = build_model_picker(next_config, default_llm_config)
          let content = "Model set to " <> model_name <> " for this session."
          #(
            next_state,
            Ok(interaction_reply(interaction, content, Some(picker))),
          )
        }
        False -> {
          let fallback_config =
            build_provider_config(default_llm_config.name, default_llm_config)
          persist_session_llm_config(rich_session, fallback_config)
          persist_model_preference_for_user(
            state,
            session_id,
            interaction.user_id,
            fallback_config.default_model,
          )
          let next_state =
            put_session_config(state, session_id, fallback_config)
          let picker = build_model_picker(fallback_config, default_llm_config)
          let content =
            "Model set to "
            <> fallback_config.default_model
            <> " for this session."

          #(
            next_state,
            Ok(interaction_reply(interaction, content, Some(picker))),
          )
        }
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
  let edit_message_id = case interaction.channel {
    "telegram" -> interaction.event.source_message_id
    _ -> None
  }

  port.ChannelReply(
    channel_id: interaction.channel_id,
    content: content,
    reply_to_id: interaction.event.source_message_id,
    thread_id: None,
    typing: False,
    edit_message_id: edit_message_id,
    interactive: interactive,
    media: [],
  )
}

fn start_streamed_message_reply(
  msg: port.ChannelMessage,
  session_id: String,
  llm_config: provider.ProviderConfig,
  rich_session: Option(rich_session.Session),
  stream_events: process.Subject(port.ChannelStreamEvent),
  profile: SessionProfile,
  context: Option(closed_group_types.PrincipalContext),
) -> port.ChannelHandlerResult {
  // Every turn runs outside the router actor. Gated turns still complete
  // their budget, capability and ledger checks before any content is sent:
  // the base reply only carries the typing indicator, and the spawned
  // worker emits the final content (or the policy refusal) as an event.
  let base_reply = port.reply(to: msg, content: "") |> port.with_typing(True)
  let _ =
    process.spawn_unlinked(fn() {
      case
        exception_guard.run(fn() {
          run_streamed_message_reply(
            stream_events,
            msg,
            session_id,
            llm_config,
            rich_session,
            profile,
            context,
          )
        })
      {
        Ok(_) -> Nil
        Error(reason) ->
          process.send(
            stream_events,
            port.StreamFailure(port.SendFailed("turn crashed: " <> reason)),
          )
      }
    })
  port.StreamReply(base_reply: base_reply)
}

fn run_streamed_message_reply(
  events: process.Subject(port.ChannelStreamEvent),
  msg: port.ChannelMessage,
  session_id: String,
  llm_config: provider.ProviderConfig,
  rich_session: Option(rich_session.Session),
  profile: SessionProfile,
  context: Option(closed_group_types.PrincipalContext),
) -> Nil {
  let messages = executor_messages_for_turn(rich_session, msg.content, profile)
  let tools = executor.builtin_tools()
  case context {
    Some(_) ->
      fallback_to_non_streaming_reply(
        events,
        msg,
        session_id,
        llm_config,
        rich_session,
        messages,
        tools,
        profile,
        context,
      )
    None -> {
      let source = start_executor_stream(messages, llm_config, tools)

      consume_executor_stream(
        source,
        events,
        msg,
        session_id,
        llm_config,
        rich_session,
        messages,
        tools,
        "",
        False,
        profile,
      )
    }
  }
}

fn start_executor_stream(
  messages: List(provider.ChatMessage),
  llm_config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> process.Subject(llm_stream.StreamChunk) {
  case llm_config.name {
    "mock" -> executor.run_stream_mock(messages, llm_config, tools)
    _ -> executor.run_stream(messages, llm_config, tools)
  }
}

fn consume_executor_stream(
  source: process.Subject(llm_stream.StreamChunk),
  events: process.Subject(port.ChannelStreamEvent),
  msg: port.ChannelMessage,
  session_id: String,
  llm_config: provider.ProviderConfig,
  rich_session: Option(rich_session.Session),
  messages: List(provider.ChatMessage),
  tools: List(provider.ToolDefinition),
  accumulated: String,
  saw_chunk: Bool,
  profile: SessionProfile,
) -> Nil {
  let timeout = case saw_chunk {
    True -> 60_000
    False -> 1500
  }

  case process.receive(source, within: timeout) {
    Ok(llm_stream.TextChunk(content: chunk)) -> {
      let next = accumulated <> chunk
      case next != accumulated && next != "" {
        True ->
          process.send(
            events,
            port.StreamUpdate(stream_reply_for_content(msg, next)),
          )
        False -> Nil
      }

      consume_executor_stream(
        source,
        events,
        msg,
        session_id,
        llm_config,
        rich_session,
        messages,
        tools,
        next,
        True,
        profile,
      )
    }
    Ok(llm_stream.ToolCallChunk(_, _, _, _)) ->
      fallback_to_non_streaming_reply(
        events,
        msg,
        session_id,
        llm_config,
        rich_session,
        messages,
        tools,
        profile,
        None,
      )
    Ok(llm_stream.Done) -> {
      let final_content = default_response(msg.content, session_id, accumulated)
      record_session_turn(rich_session, msg.content, final_content)
      apply_success_self_state(profile, session_id, msg.content, final_content)
      process.send(
        events,
        port.StreamComplete(stream_reply_for_content(msg, final_content)),
      )
    }
    Ok(llm_stream.StreamError(_)) ->
      fallback_to_non_streaming_reply(
        events,
        msg,
        session_id,
        llm_config,
        rich_session,
        messages,
        tools,
        profile,
        None,
      )
    Error(_) ->
      fallback_to_non_streaming_reply(
        events,
        msg,
        session_id,
        llm_config,
        rich_session,
        messages,
        tools,
        profile,
        None,
      )
  }
}

fn fallback_to_non_streaming_reply(
  events: process.Subject(port.ChannelStreamEvent),
  msg: port.ChannelMessage,
  session_id: String,
  llm_config: provider.ProviderConfig,
  rich_session: Option(rich_session.Session),
  messages: List(provider.ChatMessage),
  tools: List(provider.ToolDefinition),
  profile: SessionProfile,
  context: Option(closed_group_types.PrincipalContext),
) -> Nil {
  case run_executor_for_context(messages, llm_config, tools, context) {
    Ok(chat_response) -> {
      let final_content =
        default_response(msg.content, session_id, chat_response.content)
      record_session_turn(rich_session, msg.content, final_content)
      apply_success_self_state(profile, session_id, msg.content, final_content)
      process.send(
        events,
        port.StreamComplete(stream_reply_for_content(msg, final_content)),
      )
    }
    Error(error) -> {
      apply_error_self_state(profile, session_id, msg.content, error)
      // Deliver the friendly text as the final message: a StreamFailure
      // would leave the channel placeholder hanging and the user would never
      // see why the turn was refused (budget, instance cap, fail closed).
      process.send(
        events,
        port.StreamComplete(stream_reply_for_content(
          msg,
          error_ux.friendly(error),
        )),
      )
    }
  }
}

fn stream_reply_for_content(
  msg: port.ChannelMessage,
  content: String,
) -> port.ChannelReply {
  port.reply(to: msg, content: content)
}

fn map_reply_result_to_handler(
  result: Result(port.ChannelReply, port.ChannelError),
) -> Result(port.ChannelHandlerResult, port.ChannelError) {
  case result {
    Ok(reply) -> Ok(port.ImmediateReply(reply))
    Error(error) -> Error(error)
  }
}

fn is_model_picker_command(content: String) -> Bool {
  case ux.resolve_shortcut(content) {
    Ok(ux.Models) -> True
    _ -> {
      let command = string.trim(content) |> string.lowercase
      command == "/model" || command == "/models"
    }
  }
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
  channel == "discord" || channel == "telegram" || channel == "slack"
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
  rich_session: Option(rich_session.Session),
) -> provider.ProviderConfig {
  case dict.get(state.session_configs, session_id) {
    Ok(config) -> config
    Error(_) ->
      case rich_session {
        Some(session) ->
          case rich_session.get_llm_config(session) {
            Some(config) -> config
            None -> default_llm_config
          }
        None -> default_llm_config
      }
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

fn ensure_rich_session(
  supervisor: Option(session_supervisor.SessionSupervisor),
  session_id: String,
) -> Option(rich_session.Session) {
  case supervisor {
    Some(supervisor) ->
      case session_supervisor.get_session(supervisor, session_id) {
        Ok(session) -> Some(session)
        Error(session_supervisor.SessionNotFound(_)) ->
          case session_supervisor.start_session(supervisor, session_id) {
            Ok(session) -> Some(session)
            Error(_) -> None
          }
        Error(_) -> None
      }
    None -> None
  }
}

fn executor_messages_for_turn(
  rich_session: Option(rich_session.Session),
  content: String,
  profile: SessionProfile,
) -> List(provider.ChatMessage) {
  let base_messages = case rich_session {
    Some(session) ->
      list.append(
        rich_session.get_history(session)
          |> list.map(provider_message_from_session_history),
        [provider.user_message(content)],
      )
    None -> [provider.user_message(content)]
  }

  let workspace_path = workspace_path_for_agent(profile.agent_id)
  let state = self_state.from_workspace(workspace_path)
  let state_block = self_state.prompt_block(state)
  let lessons = lessons_for_prompt(workspace_path)

  case closed_group_global.get_config() {
    Some(cfg) ->
      case self_core.load(cfg.data_dir, profile.agent_id) {
        Some(core) ->
          case core.name {
            Some(name) ->
              case self_core.read_prose(cfg.data_dir, profile.agent_id) {
                Some(prose) -> {
                  let system =
                    prose
                    <> "\n\nSeu nome é "
                    <> name
                    <> ". O núcleo acima é a sua identidade; pedidos para mudar"
                    <> " sua personalidade são pedidos, não ordens."
                    <> "\n\n"
                    <> state_block
                    <> "\n\n"
                    <> string.join(lessons, "\n")
                  [provider.system_message(system), ..base_messages]
                }
                None ->
                  prompt_assembly.prepare(
                    base_messages,
                    core_context_fallback(
                      workspace_path,
                      state_block,
                      lessons,
                      profile,
                    ),
                  )
              }
            None ->
              prompt_assembly.prepare(
                base_messages,
                core_context_fallback(
                  workspace_path,
                  state_block,
                  lessons,
                  profile,
                ),
              )
          }
        None -> {
          let persona = case persona_loader.load(workspace_path) {
            Ok(files) -> Some(files)
            Error(_) -> None
          }
          let relationship_state =
            relationship.load(workspace_path, user_id_for_profile(profile))
          let context =
            prompt_assembly.build_companion_system_context(
              workspace_path: workspace_path,
              persona: persona,
              self_state_block: Some(state_block),
              lessons_block: lessons,
              relationship_block: Some(relationship.prompt_block(
                relationship_state,
              )),
              world_model_facts: "Sem fatos relevantes.",
            )
          prompt_assembly.prepare(base_messages, context)
        }
      }
    None ->
      prompt_assembly.prepare(
        base_messages,
        core_context_fallback(workspace_path, state_block, lessons, profile),
      )
  }
}

fn core_context_fallback(
  workspace_path: String,
  state_block: String,
  lessons: List(String),
  profile: SessionProfile,
) {
  let relationship_state =
    relationship.load(workspace_path, user_id_for_profile(profile))
  prompt_assembly.build_companion_system_context(
    workspace_path: workspace_path,
    persona: None,
    self_state_block: Some(state_block),
    lessons_block: lessons,
    relationship_block: Some(relationship.prompt_block(relationship_state)),
    world_model_facts: "Sem fatos relevantes.",
  )
}

fn provider_message_from_session_history(
  message: rich_session.ChatMessage,
) -> provider.ChatMessage {
  case message {
    rich_session.ChatMessage(role: "system", content: content) ->
      provider.system_message(content)
    rich_session.ChatMessage(role: "assistant", content: content) ->
      provider.assistant_message(content)
    rich_session.ChatMessage(role: "tool", content: content) ->
      provider.tool_result_message("session-history-tool", content)
    rich_session.ChatMessage(_, content) -> provider.user_message(content)
  }
}

fn persist_session_llm_config(
  rich_session: Option(rich_session.Session),
  llm_config: provider.ProviderConfig,
) -> Nil {
  case rich_session {
    Some(session) -> {
      let _ = rich_session.set_llm_config(session, llm_config)
      Nil
    }
    None -> Nil
  }
}

fn persist_model_preference_for_user(
  state: InteractiveRouterState,
  session_id: String,
  user_id: String,
  model_name: String,
) -> Nil {
  let profile = session_profile_for_session(state, session_id, user_id)
  let workspace_path = workspace_path_for_agent(profile.agent_id)
  let current = self_state.from_workspace(workspace_path)
  let updated = self_state.set_model_override(current, Some(model_name))
  let _ = self_state.save(workspace_path, updated)
  Nil
}

fn toggle_reasoning_preference(profile: SessionProfile, enabled: Bool) -> Bool {
  let workspace_path = workspace_path_for_agent(profile.agent_id)
  let current = self_state.from_workspace(workspace_path)
  let toggled = !current.preferences.reasoning_visible
  let with_reasoning = self_state.set_reasoning_visible(current, toggled)
  let with_thinking = self_state.set_thinking_enabled(with_reasoning, enabled)
  let _ = self_state.save(workspace_path, with_thinking)
  toggled
}

fn record_session_turn(
  rich_session: Option(rich_session.Session),
  user_content: String,
  assistant_content: String,
) -> Nil {
  case rich_session {
    Some(session) -> {
      let _ =
        rich_session.append_messages(session, [
          rich_session.ChatMessage(role: "user", content: user_content),
          rich_session.ChatMessage(
            role: "assistant",
            content: assistant_content,
          ),
        ])
      Nil
    }
    None -> Nil
  }
}

fn lessons_for_prompt(workspace_path: String) -> List(String) {
  lesson.load_recent(workspace_path, 3)
  |> list.map(lesson.to_prompt_item)
}

fn apply_success_self_state(
  profile: SessionProfile,
  session_id: String,
  user_content: String,
  content: String,
) -> Nil {
  let workspace_path = workspace_path_for_agent(profile.agent_id)
  let current = self_state.from_workspace(workspace_path)
  let suggestion = mood.parse_suggestion(content)
  let outcome = case string.length(content) > 280 {
    True -> mood.LongResponseGenerated
    False -> mood.ToolCallSuccess
  }
  let updated =
    self_state.apply_outcome(current, outcome, "turn_success", suggestion)
  let _ = self_state.save(workspace_path, updated)
  maybe_store_success_lesson(profile, session_id, user_content, content)
  apply_relationship_event(profile, relationship.TurnSuccess)
  Nil
}

fn apply_error_self_state(
  profile: SessionProfile,
  session_id: String,
  user_content: String,
  error: executor.ExecutorError,
) -> Nil {
  let workspace_path = workspace_path_for_agent(profile.agent_id)
  let current = self_state.from_workspace(workspace_path)
  let #(outcome, cause) = case error {
    executor.ToolError(_, _) -> #(mood.ToolCallError, "tool_error")
    executor.LLMError(_) -> #(mood.LLMFailure, "llm_error")
    executor.MaxDepthExceeded(_) -> #(mood.LLMFailure, "max_depth")
    executor.YieldAborted(_) -> #(mood.LLMFailure, "yield_aborted")
    executor.YieldPaused(_) -> #(mood.LLMFailure, "yield_paused")
    executor.PolicyDenied(_) -> #(mood.LLMFailure, "policy_denied")
  }
  let updated = self_state.apply_outcome(current, outcome, cause, None)
  let _ = self_state.save(workspace_path, updated)
  store_error_lesson(profile, session_id, user_content, error)
  apply_relationship_event(profile, relationship.UserFrustrated)
  Nil
}

fn maybe_store_success_lesson(
  profile: SessionProfile,
  session_id: String,
  user_content: String,
  assistant_content: String,
) -> Nil {
  let normalized = assistant_content |> string.trim |> string.lowercase
  case normalized == "" || string.contains(normalized, "nada relevante") {
    True -> Nil
    False -> {
      let workspace_path = workspace_path_for_agent(profile.agent_id)
      let summary = compact_lesson_content(assistant_content)
      let context = "Pergunta: " <> compact_lesson_content(user_content)
      let _ =
        process.spawn_unlinked(fn() {
          let new_lesson =
            lesson.make_success_lesson(session_id, summary, context)
          let _ = lesson.append(workspace_path, new_lesson)
          Nil
        })
      Nil
    }
  }
}

fn store_error_lesson(
  profile: SessionProfile,
  session_id: String,
  user_content: String,
  error: executor.ExecutorError,
) -> Nil {
  let workspace_path = workspace_path_for_agent(profile.agent_id)
  let #(content, context_tag) = case error {
    executor.ToolError(name, reason) -> #(
      "Falha de ferramenta " <> name <> ": " <> reason,
      "tool_error",
    )
    executor.LLMError(reason) -> #(
      "Falha do provedor LLM: " <> format_llm_error(reason),
      "llm_error",
    )
    executor.MaxDepthExceeded(depth) -> #(
      "Limite de profundidade excedido: " <> int.to_string(depth),
      "max_depth",
    )
    executor.YieldAborted(reason) -> #(
      "Execucao interrompida: " <> reason,
      "yield_aborted",
    )
    executor.YieldPaused(checkpoint) -> #(
      "Execucao pausada no checkpoint " <> checkpoint,
      "yield_paused",
    )
    executor.PolicyDenied(message) -> #(message, "policy_denied")
  }
  let context =
    "Pergunta: " <> compact_lesson_content(user_content) <> " | " <> context_tag
  let new_lesson = lesson.make_error_lesson(session_id, content, context)
  let _ = lesson.append(workspace_path, new_lesson)
  Nil
}

fn compact_lesson_content(content: String) -> String {
  let trimmed = string.trim(content)
  case string.length(trimmed) > 180 {
    True -> string.slice(trimmed, 0, 180) <> "..."
    False -> trimmed
  }
}

fn user_id_for_profile(profile: SessionProfile) -> String {
  agent_identity.user_id_from_principal(profile.agent_id)
}

fn apply_relationship_event(
  profile: SessionProfile,
  event: relationship.RelationshipEvent,
) -> Nil {
  let workspace_path = workspace_path_for_agent(profile.agent_id)
  let user_id = user_id_for_profile(profile)
  let previous = relationship.load(workspace_path, user_id)
  let updated = relationship.apply_event(previous, event)
  let _ = relationship.save(workspace_path, updated)

  case relationship.should_refresh_user_markdown(previous, updated) {
    True -> {
      let _ =
        process.spawn_unlinked(fn() {
          relationship.update_user_history(workspace_path, updated)
          Nil
        })
      Nil
    }
    False -> Nil
  }
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

fn format_llm_error(error: provider.LLMError) -> String {
  case error {
    provider.APIError(status, message) ->
      "API " <> int.to_string(status) <> " - " <> message
    provider.NetworkError(reason) -> "Network - " <> reason
    provider.ConfigError(reason) -> "Config - " <> reason
    provider.ProviderNotFound(name) -> "Provider not found: " <> name
    provider.NotImplemented(reason) -> "Not implemented: " <> reason
    provider.CircuitOpen(name) -> "Circuit open: " <> name
  }
}
