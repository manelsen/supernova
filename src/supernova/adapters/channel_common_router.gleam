//// Shared router implementation for channel adapters using the port contract.
////
//// This module centralises the common adapter flow:
//// - channel validation
//// - bot/empty message filtering
//// - session lookup via provided callback
//// - executor dispatch
//// - standardized reply/error mapping

import envoy
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/adapters/mcp/computer as mcp_computer
import supernova/adapters/model_picker
import supernova/agenda/runtime as agenda_runtime
import supernova/agenda/schedule as agenda_schedule
import supernova/agenda/store as agenda_store
import supernova/aprovacao/pedido
import supernova/aprovacao/permissoes
import supernova/aprovacao/senha
import supernova/aprovacao/servico as aprovacao_servico
import supernova/channel/apagar_mensagem
import supernova/channel/catalog as channel_catalog
import supernova/channel/inbound_media
import supernova/channel/media_reading
import supernova/channel/port
import supernova/config
import supernova/core/agent_identity
import supernova/core/audit_log/actor as audit_actor
import supernova/core/audit_log/types as audit_types
import supernova/core/closed_group/commands as closed_group_commands
import supernova/core/closed_group/global as closed_group_global
import supernova/core/closed_group/pure as closed_group_pure
import supernova/core/closed_group/runtime as closed_group_runtime
import supernova/core/closed_group/types as closed_group_types
import supernova/core/error_ux
import supernova/core/exception_guard
import supernova/core/executor
import supernova/core/introspection/mood
import supernova/core/introspection/relationship
import supernova/core/introspection/self_state
import supernova/core/media_prompts
import supernova/core/persona/loader as persona_loader
import supernova/core/persona/types as persona_types
import supernova/core/preferences
import supernova/core/prompt_assembly
import supernova/core/session/server as rich_session
import supernova/core/session/supervisor as session_supervisor
import supernova/core/syscall/actor as syscall_actor
import supernova/core/ux
import supernova/infra/safe_io
import supernova/llm/catalog
import supernova/llm/provider
import supernova/llm/providers/openai_compatible
import supernova/llm/stream as llm_stream
import supernova/memory/gate as memory_gate
import supernova/memory/metrics as memory_metrics
import supernova/self/aprovacoes
import supernova/self/audit as self_audit
import supernova/self/birth
import supernova/self/cofre
import supernova/self/core as self_core
import supernova/self/desk
import supernova/self/epoch
import supernova/self/forget
import supernova/self/incidents
import supernova/self/journal
import supernova/self/memory
import supernova/self/reflection
import supernova/self/state_store
import supernova/self/tasks
import supernova/self/template as prompt_template
import supernova/sondas/condutor as sonda_condutor
import supernova/sondas/sonda
import supernova/tools/agenda as agenda_tool
import supernova/tools/computador as computador_tool
import supernova/tools/tarefa

/// Function to resolve/create a session id for an incoming message.
pub type ResolveSession =
  fn(port.ChannelMessage) -> String

/// Function to resolve/create a session id from channel and user identifiers.
pub type ResolveSessionFromParticipant =
  fn(String, String) -> String

/// The router's state: a scope in a public ETS table, not data in the
/// router's process (PRD-P, P-04). Every router (one per channel) has its
/// own scope; any process holding it reads and writes the same state, so the
/// pre-LLM phase can run outside the router's actor (P-05).
///
/// In the scope:
/// - the session profiles, by session;
/// - the provider and model picked with /model, by agent (the state file
///   keeps them across restarts; this spares reading it again);
/// - the /esquecer waiting for confirmation, by agent.
pub opaque type InteractiveRouterState {
  InteractiveRouterState(scope: Int)
}

type RouterTable {
  SupernovaRouterState
}

type RouterKey {
  ProfileKey(scope: Int, session_id: String)
  ChoiceKey(scope: Int, agent_id: String)
  ForgetKey(scope: Int, agent_id: String)
}

@external(erlang, "supernova_table_ffi", "get")
fn router_get(table: RouterTable, key: RouterKey) -> Result(v, Nil)

@external(erlang, "supernova_table_ffi", "put")
fn router_put(table: RouterTable, key: RouterKey, value: v) -> Nil

@external(erlang, "supernova_table_ffi", "delete")
fn router_delete(table: RouterTable, key: RouterKey) -> Nil

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn get_profile(
  state: InteractiveRouterState,
  session_id: String,
) -> Result(SessionProfile, Nil) {
  router_get(SupernovaRouterState, ProfileKey(state.scope, session_id))
}

fn get_choice(
  state: InteractiveRouterState,
  agent_id: String,
) -> Result(provider.ProviderConfig, Nil) {
  router_get(SupernovaRouterState, ChoiceKey(state.scope, agent_id))
}

fn put_choice(
  state: InteractiveRouterState,
  agent_id: String,
  config: provider.ProviderConfig,
) -> InteractiveRouterState {
  router_put(SupernovaRouterState, ChoiceKey(state.scope, agent_id), config)
  state
}

fn get_forget_pending(
  state: InteractiveRouterState,
  agent_id: String,
) -> Result(Int, Nil) {
  router_get(SupernovaRouterState, ForgetKey(state.scope, agent_id))
}

fn put_forget_pending(
  state: InteractiveRouterState,
  agent_id: String,
  at: Int,
) -> InteractiveRouterState {
  router_put(SupernovaRouterState, ForgetKey(state.scope, agent_id), at)
  state
}

fn drop_forget_pending(
  state: InteractiveRouterState,
  agent_id: String,
) -> InteractiveRouterState {
  router_delete(SupernovaRouterState, ForgetKey(state.scope, agent_id))
  state
}

/// Whether the router's scope holds nothing yet for this session and agent.
pub fn is_empty_for(
  state: InteractiveRouterState,
  session_id: String,
  agent_id: String,
) -> Bool {
  get_profile(state, session_id) == Error(Nil)
  && get_choice(state, agent_id) == Error(Nil)
  && get_forget_pending(state, agent_id) == Error(Nil)
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
    /// Forget epoch when this message arrived. A turn that finishes after
    /// /esquecer must not write memory.
    turn_epoch: Int,
  )
}

/// Create a new empty interactive router state.
pub fn new_interactive_state() -> InteractiveRouterState {
  InteractiveRouterState(scope: unique_integer())
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

/// One tool call of a turn and what it returned, kept in the conversation
/// so the next turns see the evidence the reply was built on.
pub type ToolRound {
  ToolRound(name: String, arguments: String, result: String)
}

/// A turn: the reply, and the tool calls made on the way to it.
fn run_executor_for_context(
  messages: List(provider.ChatMessage),
  llm_config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
  context: Option(closed_group_types.PrincipalContext),
  msg: port.ChannelMessage,
  agent_id: String,
) -> #(Result(provider.ChatResponse, executor.ExecutorError), List(ToolRound)) {
  case context, closed_group_global.get_runtime() {
    Some(turn), Some(runtime) -> {
      // Owned by this turn's process: the gateway calls report here, and
      // the turn collects them once the executor is done.
      let rounds = process.new_subject()
      let run_context =
        executor.RunContext(
          ..closed_group_runtime.run_context(runtime, turn),
          purpose: "turn",
        )
      // `tarefa` needs the chat of origin, which only the turn knows; the
      // task's own tool call goes through the gateway like any other
      // (PRD-F, F-05).
      let origin =
        tasks.Origin(
          agent_id: agent_id,
          principal: turn.principal_id,
          role: turn.role,
          channel: msg.channel,
          channel_id: msg.channel_id,
          user_id: msg.user_id,
        )
      let may_start_tasks =
        closed_group_runtime.tools_for(runtime, turn.role, [tarefa.tool()])
        != []
      // Probes (PRD-S): the code probe only for who has the computer (S15).
      let may_probe =
        closed_group_runtime.tools_for(runtime, turn.role, [sonda.tool(False)])
        != []
      let may_code =
        closed_group_runtime.tools_for(runtime, turn.role, [
          computador_tool.tool(),
        ])
        != []
      let probe_env = fn(invoke) {
        sonda.Env(
          llm_config: llm_config,
          base: run_context,
          gateway: invoke,
          audited: fn(action, run) {
            syscall_actor.invoke_tool_with(
              runtime.gateway,
              turn.principal_id,
              turn.role,
              sonda.name,
              action,
              run,
            )
          },
          may_code: may_code,
          costing: sonda_condutor.Costing(
            cost: fn(model, prompt, completion) {
              closed_group_runtime.llm_cost_usd(
                runtime,
                model,
                prompt,
                completion,
              )
            },
            reserve_output_tokens: closed_group_runtime.reserve_output_tokens(
              runtime,
            ),
          ),
          computer: mcp_computer.from_env(),
        )
      }
      let recorded =
        executor.RunContext(
          ..run_context,
          invoke_tool: option.map(run_context.invoke_tool, fn(invoke) {
            fn(name, arguments) {
              let result = case name {
                _ if name == tarefa.name ->
                  case may_start_tasks {
                    True -> tarefa.execute(origin, arguments, invoke)
                    False -> Error("tarefa não é permitida para você")
                  }
                _ if name == sonda.name ->
                  case may_probe {
                    True -> sonda.execute(origin, arguments, probe_env(invoke))
                    False -> Error("sonda não é permitida para você")
                  }
                // A site for the shell (PRD-K, K21): a request to the person,
                // born in this chat; the first sentence is the code's.
                _ if name == computador_tool.name ->
                  case
                    computador_tool.site_request(arguments),
                    computador_tool.login_request(arguments),
                    computador_tool.screen_request(arguments),
                    may_code
                  {
                    Some(_), _, _, False
                    | _, Some(_), _, False
                    | _, _, Some(_), False
                    -> Error("computador não é permitido para você")
                    Some(asked), _, _, True ->
                      ask_for_site(turn.principal_id, msg, asked)
                    None, Some(site), _, True ->
                      log_in(turn.principal_id, msg, site)
                    // The person's screen, by a link in private (K-09).
                    None, None, Some(reason), True ->
                      call_person_to_screen(turn.principal_id, reason)
                    // What the browser gate refused becomes a request to the
                    // person (PRD-K, K-06).
                    None, None, None, _ ->
                      invoke(name, arguments)
                      |> result.map(fn(text) {
                        case computador_tool.gate_refusal(text) {
                          Some(refusal) ->
                            text
                            <> "\n\n"
                            <> ask_for_gate(turn.principal_id, msg, refusal)
                          None -> text
                        }
                      })
                  }
                _ -> invoke(name, arguments)
              }
              process.send(
                rounds,
                ToolRound(
                  name: name,
                  arguments: arguments,
                  result: case result {
                    Ok(output) -> output
                    Error(reason) -> "ERROR: " <> reason
                  },
                ),
              )
              result
            }
          }),
        )
      // The person wrote: results that waited for budget go now (D5).
      case is_synthetic(msg.id) {
        True -> Nil
        False -> tasks.person_active(agent_id)
      }
      let offered =
        closed_group_runtime.tools_for(runtime, turn.role, tools)
        |> list.map(fn(tool) {
          case tool.name == sonda.name {
            True -> sonda.tool(may_code)
            False -> tool
          }
        })
      let result =
        executor.run_with_context(messages, llm_config, offered, recorded)
      #(result, list.append(task_rounds(msg.id), drain_rounds(rounds, [])))
    }
    _, _ -> #(ungoverned_run(messages, llm_config, tools), [])
  }
}

/// Messages the core made itself: an agenda entry, a task result, an
/// approval's outcome.
fn is_synthetic(message_id: String) -> Bool {
  string.starts_with(message_id, "agenda:")
  || string.starts_with(message_id, "tarefa:")
  || string.starts_with(message_id, "aprovacao:")
}

/// `pedir_tela` (PRD-K, K15, K16, K-09): the screen opens and the link goes
/// to the person's private chat; they open it, or forward it to whoever
/// helps them.
fn call_person_to_screen(
  principal: String,
  reason: String,
) -> Result(String, String) {
  case aprovacao_servico.get() {
    None -> Error("não consigo falar com a sua pessoa agora")
    Some(context) -> {
      use url <- result.try(computador_tool.open_screen(principal))
      let why = case reason {
        "" -> ""
        _ -> " " <> reason
      }
      let text =
        "A agente precisa de você no computador."
        <> why
        <> "\n\nAbra este link para ver e usar a tela: "
        <> url
        <> "\n\nVale por 15 minutos e abre uma vez só. Pode encaminhar a quem for ajudar você. Quando terminar, avise a agente."
      use _ <- result.try(context.send_private(principal, text, None))
      Ok(
        "Mandei à sua pessoa, no privado, o link da tela (vale 15 minutos). Espere ela dizer que terminou; depois use devolver_tela.",
      )
    }
  }
}

/// `entrar` (PRD-K, K-08): entering an account asks the person (K2), unless
/// they allowed it for good; the password comes from the vault, for this
/// call only, and nothing of it reaches the model.
fn log_in(
  principal: String,
  msg: port.ChannelMessage,
  site: String,
) -> Result(String, String) {
  case closed_group_global.get_config(), cofre.key(), aprovacao_servico.get() {
    None, _, _ | _, Error(Nil), _ ->
      Error("o cofre de senhas não está ligado nesta instalação")
    _, _, None -> Error("aprovações não estão disponíveis agora")
    Some(cfg), Ok(key), Some(context) ->
      case cofre.credencial(cfg.data_dir, principal, key, site) {
        Error(_) ->
          Ok(
            "Sua pessoa não guardou senha para "
            <> site
            <> ". Peça que ela mande, no privado: /senha "
            <> site
            <> " usuário senha. Você nunca vê a senha.",
          )
        Ok(#(usuario, password)) ->
          case
            aprovacoes.allowed(
              cfg.data_dir,
              principal,
              context.clock(),
              aprovacoes.Login,
              site,
              None,
            )
          {
            Ok(True) ->
              computador_tool.entrar(principal, site, usuario, password)
            Ok(False) ->
              aprovacao_servico.pedir(
                context,
                principal,
                aprovacoes.Draft(
                  kind: aprovacoes.Login,
                  target: site,
                  summary: pedido.first_sentence(
                    "Entrar na sua conta em "
                    <> site
                    <> " (usuário "
                    <> usuario
                    <> ").",
                  ),
                  explanation: "",
                  task: None,
                  approve: aprovacoes.Once,
                  always: True,
                  origin: aprovacoes.Chat(
                    msg.channel,
                    msg.channel_id,
                    msg.user_id,
                  ),
                ),
                in_group: !closed_group_pure.is_private_chat(
                  msg.channel,
                  msg.channel_id,
                ),
              )
            Error(reason) -> Error(reason)
          }
      }
  }
}

/// The browser gate refused (K-06): the person is asked, in private, with a
/// first sentence the code writes from what was refused (K7, K-I5).
fn ask_for_gate(
  principal: String,
  msg: port.ChannelMessage,
  refusal: computador_tool.Refusal,
) -> String {
  let draft = case refusal.tipo {
    "envio" ->
      Ok(aprovacoes.Draft(
        kind: aprovacoes.Send,
        target: "envio:" <> refusal.site,
        summary: pedido.first_sentence(case refusal.campos {
          "" -> "Enviar o formulário em " <> refusal.site <> "."
          campos ->
            "Enviar o formulário em " <> refusal.site <> ": " <> campos <> "."
        }),
        explanation: "",
        task: None,
        approve: aprovacoes.Once,
        always: False,
        origin: aprovacoes.Chat(msg.channel, msg.channel_id, msg.user_id),
      ))
    "site" ->
      Ok(aprovacoes.Draft(
        kind: aprovacoes.Send,
        target: "site:" <> refusal.site,
        summary: pedido.first_sentence(
          "Usar o site "
          <> refusal.site
          <> ", que quer receber dados da página (buscas, cliques, carrinho).",
        ),
        explanation: "",
        task: None,
        approve: aprovacoes.Window(aprovacoes.one_hour_ms),
        always: True,
        origin: aprovacoes.Chat(msg.channel, msg.channel_id, msg.user_id),
      ))
    "arquivo" ->
      Ok(aprovacoes.Draft(
        kind: aprovacoes.Overwrite,
        target: refusal.caminho,
        summary: pedido.first_sentence(case refusal.acao {
          "apagar" -> "Apagar o arquivo " <> refusal.caminho <> "."
          _ ->
            "Sobrescrever o arquivo "
            <> refusal.caminho
            <> " com um texto novo."
        }),
        explanation: "",
        task: None,
        approve: aprovacoes.Once,
        always: False,
        origin: aprovacoes.Chat(msg.channel, msg.channel_id, msg.user_id),
      ))
    _ -> Error(Nil)
  }
  case draft, aprovacao_servico.get() {
    Ok(draft), Some(context) ->
      case
        aprovacao_servico.pedir(
          context,
          principal,
          draft,
          in_group: !closed_group_pure.is_private_chat(
            msg.channel,
            msg.channel_id,
          ),
        )
      {
        Ok(note) -> note
        Error(reason) -> "Não consegui pedir aprovação: " <> reason
      }
    Error(Nil), _ -> "O portão barrou o envio."
    Ok(_), None ->
      "O portão barrou o envio, e aprovações não estão disponíveis agora."
  }
}

/// `pedir_site`: the person is asked, in private, to let the shell reach a
/// site (PRD-K, K21). Approving adds it to their list for good.
fn ask_for_site(
  principal: String,
  msg: port.ChannelMessage,
  asked: Result(computador_tool.SiteRequest, String),
) -> Result(String, String) {
  case asked, aprovacao_servico.get() {
    Error(reason), _ -> Error(reason)
    Ok(_), None -> Error("aprovações não estão disponíveis agora")
    Ok(computador_tool.SiteRequest(site, reason)), Some(context) ->
      aprovacao_servico.pedir(
        context,
        principal,
        aprovacoes.Draft(
          kind: aprovacoes.ShellSite,
          target: site,
          summary: "Liberar o site "
            <> site
            <> " para o shell do seu computador baixar arquivos.",
          explanation: reason,
          task: None,
          approve: aprovacoes.Permanent,
          always: False,
          origin: aprovacoes.Chat(msg.channel, msg.channel_id, msg.user_id),
        ),
        in_group: !closed_group_pure.is_private_chat(
          msg.channel,
          msg.channel_id,
        ),
      )
  }
}

/// A task result arriving as a message is kept in the history as the tool
/// call it was, like the calls of a turn (#59, PRD-F F-06).
fn task_rounds(message_id: String) -> List(ToolRound) {
  case closed_group_global.get_config() {
    None -> []
    Some(cfg) ->
      case tasks.result_for_message(cfg.data_dir, message_id) {
        Some(task) -> [
          ToolRound(
            name: task.tool,
            arguments: task.arguments,
            result: task.result,
          ),
        ]
        None -> []
      }
  }
}

fn drain_rounds(
  rounds: process.Subject(ToolRound),
  acc: List(ToolRound),
) -> List(ToolRound) {
  case process.receive(rounds, within: 0) {
    Ok(round) -> drain_rounds(rounds, [round, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

fn run_executor_for_context_with_purpose(
  messages: List(provider.ChatMessage),
  llm_config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
  context: Option(closed_group_types.PrincipalContext),
  purpose: String,
) -> Result(provider.ChatResponse, executor.ExecutorError) {
  case context, closed_group_global.get_runtime() {
    Some(turn), Some(runtime) -> {
      let filtered = closed_group_runtime.tools_for(runtime, turn.role, tools)
      executor.run_with_context(
        messages,
        llm_config,
        filtered,
        executor.RunContext(
          ..closed_group_runtime.run_context(runtime, turn),
          purpose: purpose,
        ),
      )
    }
    _, _ -> ungoverned_run(messages, llm_config, tools)
  }
}

/// `executor.run`, unless production refuses it (`ungoverned_turn`).
fn ungoverned_run(
  messages: List(provider.ChatMessage),
  llm_config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, executor.ExecutorError) {
  ungoverned_turn(closed_group_global.is_enforced(), fn() {
    executor.run(messages, llm_config, tools)
  })
}

/// A turn with no closed-group context or runtime runs without the gateway
/// only outside production; in production it is refused (PRD-E, E-04).
pub fn ungoverned_turn(
  enforced: Bool,
  run: fn() -> Result(provider.ChatResponse, executor.ExecutorError),
) -> Result(provider.ChatResponse, executor.ExecutorError) {
  case enforced {
    True ->
      Error(executor.PolicyDenied("kernel policy unavailable for this turn"))
    False -> run()
  }
}

fn run_executor_for_name(
  messages: List(provider.ChatMessage),
  llm_config: provider.ProviderConfig,
  context: closed_group_types.PrincipalContext,
  call_id: String,
) -> Result(provider.ChatResponse, executor.ExecutorError) {
  case closed_group_global.get_runtime() {
    Some(runtime) ->
      executor.run_with_context(
        messages,
        llm_config,
        [],
        executor.RunContext(
          ..closed_group_runtime.run_context(runtime, context),
          purpose: "name",
          call_id_override: Some(call_id),
        ),
      )
    None -> ungoverned_run(messages, llm_config, [])
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
              let #(state_with_profile, llm_config) =
                agent_llm_config(
                  state_with_profile,
                  profile.agent_id,
                  default_llm_config,
                )

              case
                maybe_handle_control(
                  state_with_profile,
                  msg,
                  profile,
                  supervisor,
                  rich_session,
                )
              {
                Some(#(next_state, content)) -> #(
                  next_state,
                  Ok(port.ImmediateReply(port.reply(to: msg, content: content))),
                )
                None ->
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
                              let #(next_state, result) = case kind, context {
                                // In the closed group, /help lists the
                                // commands that exist there, by role.
                                HelpCommand, Some(ctx)
                                | CommandsCommand, Some(ctx)
                                -> #(
                                  state_with_profile,
                                  Ok(port.reply(
                                    to: msg,
                                    content: closed_group_commands.help_text(
                                      ctx.role == "admin",
                                    ),
                                  )),
                                )
                                _, _ ->
                                  handle_bootstrap_command(
                                    kind,
                                    msg,
                                    llm_config,
                                    state_with_profile,
                                    session_id,
                                  )
                              }

                              #(next_state, map_reply_result_to_handler(result))
                            }
                          }
                        None ->
                          case
                            model_command_reply(
                              expected_channel,
                              msg,
                              profile,
                              llm_config,
                              default_llm_config,
                              state_with_profile,
                            )
                          {
                            Some(#(next_state, reply)) -> #(
                              next_state,
                              Ok(port.ImmediateReply(reply)),
                            )
                            None ->
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
              let #(state_with_profile, llm_config) =
                agent_llm_config(
                  state_with_profile,
                  profile.agent_id,
                  default_llm_config,
                )

              case
                maybe_handle_control(
                  state_with_profile,
                  msg,
                  profile,
                  supervisor,
                  rich_session,
                )
              {
                Some(#(next_state, content)) -> #(
                  next_state,
                  Ok(port.reply(to: msg, content: content)),
                )
                None ->
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
                      case
                        model_command_reply(
                          expected_channel,
                          msg,
                          profile,
                          llm_config,
                          default_llm_config,
                          state_with_profile,
                        )
                      {
                        Some(#(next_state, reply)) -> #(next_state, Ok(reply))
                        None ->
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
                              let #(turn_result, rounds) =
                                run_executor_for_context(
                                  messages,
                                  llm_config,
                                  executor.builtin_tools(),
                                  context,
                                  msg,
                                  profile.agent_id,
                                )
                              case turn_result {
                                Ok(chat_response) -> {
                                  record_session_turn(
                                    rich_session,
                                    msg.content,
                                    rounds,
                                    chat_response.content,
                                  )
                                  apply_success_self_state(
                                    profile,
                                    session_id,
                                    msg.content,
                                    chat_response.content,
                                    llm_config,
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
                                    port.SendFailed(reason: error_ux.friendly(
                                      error,
                                    )),
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
      // The closed group has no /start: its agents are born ready.
      let session_line = case
        closed_self_dir_for_agent(profile.agent_id),
        profile.bootstrapped
      {
        Some(_), _ -> ""
        None, True -> "\nSessão: pronta"
        None, False -> "\nSessão: não iniciada (/start)"
      }
      #(
        state,
        Ok(port.reply(
          to: msg,
          content: "Agente: "
            <> profile.agent_id
            <> "\n"
            <> model_picker.status_lines(llm_config)
            <> session_line
            <> "\nPara trocar: /model",
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
  let profile = case get_profile(state, session_id) {
    Ok(profile) -> profile
    Error(_) ->
      SessionProfile(
        agent_id: agent_identity.principal_from_session_id(session_id),
        bootstrapped: False,
        display_name: "",
        bootstrap_state: persona_types.AskingName,
        awaiting_bootstrap_answer: False,
        draft: persona_types.BootstrapDraft(name: None, soul: None, style: None),
        turn_epoch: 0,
      )
  }
  SessionProfile(..profile, turn_epoch: forget_epoch_for(profile.agent_id))
}

fn forget_epoch_for(agent_id: String) -> Int {
  case closed_self_dir_for_agent(agent_id), closed_group_global.get_config() {
    Some(_), Some(cfg) -> epoch.current(cfg.data_dir, agent_id)
    _, _ -> 0
  }
}

/// False when the owner forgot while this turn was running.
fn turn_still_current(profile: SessionProfile) -> Bool {
  case
    closed_self_dir_for_agent(profile.agent_id),
    closed_group_global.get_config()
  {
    Some(_), Some(cfg) ->
      epoch.unchanged(cfg.data_dir, profile.agent_id, profile.turn_epoch)
    _, _ -> True
  }
}

fn put_session_profile(
  state: InteractiveRouterState,
  session_id: String,
  profile: SessionProfile,
) -> InteractiveRouterState {
  router_put(SupernovaRouterState, ProfileKey(state.scope, session_id), profile)
  state
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

fn closed_self_dir_for_agent(agent_id: String) -> Option(String) {
  closed_data_dir()
  |> option.map(agent_identity.self_dir(_, agent_id))
}

/// The data dir of the closed group, when it is in force.
fn closed_data_dir() -> Option(String) {
  case closed_group_global.get_config() {
    Some(cfg) ->
      case cfg.access.mode {
        config.Allowlist -> Some(cfg.data_dir)
        config.Open -> None
      }
    None -> None
  }
}

fn migrate_self_state_for_agent(agent_id: String, self_dir: String) -> Nil {
  let _ =
    state_store.migrate_legacy(workspace_path_for_agent(agent_id), self_dir)
  Nil
}

fn load_self_state_for_agent(agent_id: String) -> self_state.SelfState {
  case closed_data_dir() {
    Some(data_dir) -> {
      migrate_self_state_for_agent(
        agent_id,
        agent_identity.self_dir(data_dir, agent_id),
      )
      desk.read_self(data_dir, agent_id)
    }
    None -> self_state.from_workspace(workspace_path_for_agent(agent_id))
  }
}

/// Change the agent's state: in the closed group, through the agent's
/// process (one change at a time per agent, so none is lost).
fn modify_self_state_for_agent(
  agent_id: String,
  change: fn(self_state.SelfState) -> self_state.SelfState,
) -> Nil {
  case closed_data_dir() {
    Some(data_dir) -> {
      migrate_self_state_for_agent(
        agent_id,
        agent_identity.self_dir(data_dir, agent_id),
      )
      let _ = desk.modify_self(data_dir, agent_id, change)
      Nil
    }
    None -> {
      let workspace_path = workspace_path_for_agent(agent_id)
      let _ =
        self_state.save(
          workspace_path,
          change(self_state.from_workspace(workspace_path)),
        )
      Nil
    }
  }
}

fn load_relationship_for_agent(
  agent_id: String,
  user_id: String,
) -> relationship.RelationshipState {
  case closed_data_dir() {
    Some(data_dir) -> {
      migrate_self_state_for_agent(
        agent_id,
        agent_identity.self_dir(data_dir, agent_id),
      )
      desk.read_relationship(data_dir, agent_id, user_id)
    }
    None -> relationship.load(workspace_path_for_agent(agent_id), user_id)
  }
}

/// Change the agent's relationship with `user_id`; before and after.
fn modify_relationship_for_agent(
  agent_id: String,
  user_id: String,
  change: fn(relationship.RelationshipState) -> relationship.RelationshipState,
) -> #(relationship.RelationshipState, relationship.RelationshipState) {
  case closed_data_dir() {
    Some(data_dir) -> {
      migrate_self_state_for_agent(
        agent_id,
        agent_identity.self_dir(data_dir, agent_id),
      )
      desk.modify_relationship(data_dir, agent_id, user_id, change)
    }
    None -> {
      let workspace_path = workspace_path_for_agent(agent_id)
      let previous = relationship.load(workspace_path, user_id)
      let updated = change(previous)
      let _ = relationship.save(workspace_path, updated)
      #(previous, updated)
    }
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
    Some(_) ->
      // The closed group has no workspace persona (its agents are born with
      // a core): reading one on every message only held the router up.
      case
        profile.awaiting_bootstrap_answer,
        closed_self_dir_for_agent(profile.agent_id)
      {
        True, _ | _, Some(_) -> #(state, profile)
        False, None -> {
          let synced = sync_session_profile_from_workspace(profile)
          #(put_session_profile(state, session_id, synced), synced)
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
    Some(cfg) -> self_core.named(cfg.data_dir, agent_id)
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
    Some(cfg), Some(turn_context) ->
      case cfg.access.mode {
        config.Allowlist -> {
          let principal_id =
            agent_identity.principal_id(msg.channel, msg.user_id)
          let now = closed_group_global.now()
          let generate = fn(prompt: String) {
            case
              run_executor_for_context_with_purpose(
                [provider.user_message(prompt)],
                llm_config,
                [],
                context,
                "birth",
              )
            {
              Ok(response) -> Ok(response.content)
              Error(_) -> Error("birth generation failed")
            }
          }
          let extract = fn(prompt: String) {
            case
              run_executor_for_name(
                [provider.user_message(prompt)],
                llm_config,
                turn_context,
                "name:" <> principal_id <> ":" <> int.to_string(now),
              )
            {
              Ok(response) -> Ok(response.content)
              Error(_) -> Error("name extraction failed")
            }
          }
          // One birth per agent, even with first messages from two chats or
          // channels at once (D3): the second sees the agent born.
          let run_step = fn() {
            birth.step(
              cfg.data_dir,
              principal_id,
              msg.content,
              now,
              generate,
              extract,
            )
          }
          // A named agent is the common case and needs no lock (the check is
          // a cached read); otherwise, inside it, birth.step checks again.
          let step = case self_core.named(cfg.data_dir, principal_id) {
            True -> birth.AlreadyBorn
            False -> desk.exclusive(cfg.data_dir, principal_id, run_step)
          }
          case step {
            birth.AskName(text) -> Some(port.reply(to: msg, content: text))
            birth.ConfirmName(name) ->
              Some(port.reply(to: msg, content: birth.confirm_message(name)))
            birth.NameRejected(text) -> Some(port.reply(to: msg, content: text))
            birth.NameAccepted(name) ->
              Some(port.reply(to: msg, content: birth.accepted_message(name)))
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
                      modify_self_state_for_agent(profile.agent_id, fn(_) {
                        self_state.default()
                      })
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
) -> #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)) {
  let session_id = resolve_session(interaction.channel_id, interaction.user_id)
  let profile =
    session_profile_for_session(state, session_id, interaction.user_id)
  case approval_button(interaction, profile) {
    Some(content) -> #(state, Ok(interaction_reply(interaction, content, None)))
    None ->
      handle_picker_interaction(
        expected_channel,
        interaction,
        default_llm_config,
        state,
        profile,
      )
  }
}

/// An approval button (PRD-K, K-02): the code decides, in the presser's own
/// requests, so nobody else's press can reach them (K-I2).
fn approval_button(
  interaction: port.ChannelInteractionMessage,
  profile: SessionProfile,
) -> Option(String) {
  case aprovacao_servico.get() {
    None -> None
    Some(context) ->
      aprovacao_servico.answer_button(
        context,
        profile.agent_id,
        interaction.event.action_id,
      )
  }
}

fn handle_picker_interaction(
  expected_channel: String,
  interaction: port.ChannelInteractionMessage,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
  profile: SessionProfile,
) -> #(InteractiveRouterState, Result(port.ChannelReply, port.ChannelError)) {
  let cat = catalog.current(default_llm_config)
  let #(state, active) =
    agent_llm_config(state, profile.agent_id, default_llm_config)
  let answer = fn(next_state, content, shown) {
    #(
      next_state,
      Ok(interaction_reply(
        interaction,
        content,
        Some(model_picker.picker(cat, shown)),
      )),
    )
  }

  case channel_supports_interactions(expected_channel) {
    False -> #(
      state,
      Error(port.UnsupportedInteraction(
        reason: "Interactive callbacks not supported for channel: "
        <> expected_channel,
      )),
    )
    True ->
      case model_picker.parse_provider_action(interaction.event.action_id) {
        // A provider button switches to that provider's configured model and
        // shows its list.
        Some(provider_name) ->
          case catalog.provider_config(cat, provider_name) {
            Some(_) if provider_name == active.name ->
              answer(state, model_picker.unchanged_text(active), active)
            Some(chosen) ->
              answer(
                choose_model(state, profile.agent_id, chosen),
                model_picker.chosen_text(chosen),
                chosen,
              )
            None -> #(
              state,
              Error(port.UnsupportedInteraction(
                reason: "Unknown provider selection: " <> provider_name,
              )),
            )
          }
        None ->
          case
            interaction.event.action_id == model_picker.model_action,
            interaction.event.values
          {
            True, [value, ..] ->
              case
                catalog.resolve(
                  cat,
                  model_picker.decode_selection(value, active.name),
                )
              {
                Some(chosen) if chosen == active ->
                  answer(state, model_picker.unchanged_text(active), active)
                Some(chosen) ->
                  answer(
                    choose_model(state, profile.agent_id, chosen),
                    model_picker.chosen_text(chosen),
                    chosen,
                  )
                None ->
                  answer(state, model_picker.unavailable_text(active), active)
              }
            True, [] -> #(
              state,
              Error(port.UnsupportedInteraction(
                reason: "Model selection interaction missing values",
              )),
            )
            False, _ -> #(
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

/// The provider and model this agent uses: the one picked with /model, when
/// it is still configured, else the default. The state file is read once per
/// agent; the answer is kept in the router's scope for the next messages. The
/// catalog is built once at boot, so a kept answer cannot go stale.
fn agent_llm_config(
  state: InteractiveRouterState,
  agent_id: String,
  default_llm_config: provider.ProviderConfig,
) -> #(InteractiveRouterState, provider.ProviderConfig) {
  case get_choice(state, agent_id) {
    Ok(config) -> #(state, config)
    Error(_) -> {
      let config = kept_choice(agent_id, catalog.current(default_llm_config))
      #(put_choice(state, agent_id, config), config)
    }
  }
}

fn kept_choice(
  agent_id: String,
  cat: catalog.Catalog,
) -> provider.ProviderConfig {
  let preferences = load_self_state_for_agent(agent_id).preferences
  case preferences.model_override {
    Some(model) -> {
      // Files written before the provider was kept: the model belonged to
      // the default provider.
      let provider_name =
        option.unwrap(preferences.provider_override, cat.default.name)
      case catalog.resolve(cat, catalog.Choice(provider_name, model)) {
        Some(config) -> config
        None -> cat.default
      }
    }
    None -> cat.default
  }
}

/// Keep the choice for the agent, in memory and in its state file.
fn choose_model(
  state: InteractiveRouterState,
  agent_id: String,
  chosen: provider.ProviderConfig,
) -> InteractiveRouterState {
  modify_self_state_for_agent(agent_id, fn(current) {
    self_state.set_model_choice(current, chosen.name, chosen.default_model)
  })
  put_choice(state, agent_id, chosen)
}

/// /model alone shows what is in use and the choices; /model <modelo> picks.
fn model_command_reply(
  expected_channel: String,
  msg: port.ChannelMessage,
  profile: SessionProfile,
  active: provider.ProviderConfig,
  default_llm_config: provider.ProviderConfig,
  state: InteractiveRouterState,
) -> Option(#(InteractiveRouterState, port.ChannelReply)) {
  let cat = catalog.current(default_llm_config)
  case model_picker.parse(msg.content) {
    None -> None
    Some(model_picker.Show) ->
      case channel_supports_interactions(expected_channel) {
        True ->
          Some(#(
            state,
            port.reply_with_interactions(
              to: msg,
              content: model_picker.intro(active),
              interactive: model_picker.picker(cat, active),
            ),
          ))
        False ->
          Some(#(
            state,
            port.reply(to: msg, content: model_picker.text_choices(cat, active)),
          ))
      }
    Some(model_picker.Pick(argument)) ->
      case model_picker.resolve_typed(cat, active, argument) {
        Some(chosen) if chosen == active ->
          Some(#(
            state,
            port.reply(to: msg, content: model_picker.unchanged_text(active)),
          ))
        Some(chosen) ->
          Some(#(
            choose_model(state, profile.agent_id, chosen),
            port.reply(to: msg, content: model_picker.chosen_text(chosen)),
          ))
        None ->
          Some(#(
            state,
            port.reply(
              to: msg,
              content: model_picker.unknown_text(cat, active, argument),
            ),
          ))
      }
  }
}

fn interaction_reply(
  interaction: port.ChannelInteractionMessage,
  content: String,
  interactive: Option(port.ChannelInteractiveReply),
) -> port.ChannelReply {
  let edit_message_id = case
    channel_catalog.get(interaction.channel).edits_interaction_source
  {
    True -> interaction.event.source_message_id
    False -> None
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
  // The turn counts among the agent's turns in flight before it runs, so an
  // /esquecer that comes after waits for it (and one in progress makes it
  // wait). The router waits for that, so no /esquecer slips in between.
  let counted = process.new_subject()
  // Linked to the process that called the handler (the lane's shell, PRD-F
  // F-04): when the lane gives up on the turn and stops the shell, the turn
  // stops too, and its tool calls with it.
  let _ =
    process.spawn(fn() {
      case closed_data_dir() {
        Some(data_dir) ->
          desk.turn_started(data_dir, profile.agent_id, process.self())
        None -> Nil
      }
      process.send(counted, Nil)
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
  let _ = process.receive(counted, within: desk.forget_wait_ms + 30_000)
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
      record_session_turn(rich_session, msg.content, [], final_content)
      apply_success_self_state(
        profile,
        session_id,
        msg.content,
        final_content,
        llm_config,
      )
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
  let #(turn_result, rounds) =
    run_executor_for_context(
      messages,
      llm_config,
      tools,
      context,
      msg,
      profile.agent_id,
    )
  case turn_result {
    Ok(chat_response) -> {
      let final_content =
        default_response(msg.content, session_id, chat_response.content)
      record_session_turn(rich_session, msg.content, rounds, final_content)
      apply_success_self_state(
        profile,
        session_id,
        msg.content,
        final_content,
        llm_config,
      )
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

fn channel_supports_interactions(channel: String) -> Bool {
  channel_catalog.get(channel).supports_interactions
}

/// Commands answered without the model: /agenda first, then /esquecer.
fn maybe_handle_control(
  state: InteractiveRouterState,
  msg: port.ChannelMessage,
  profile: SessionProfile,
  supervisor: Option(session_supervisor.SessionSupervisor),
  rich_session: Option(rich_session.Session),
) -> Option(#(InteractiveRouterState, String)) {
  // A password goes to the vault and nowhere else, before anything else
  // reads the message (PRD-K, K-08, K-I3).
  case maybe_handle_senha(msg, profile) {
    Some(reply) -> Some(#(state, reply))
    None ->
      maybe_handle_control_rest(state, msg, profile, supervisor, rich_session)
  }
}

fn maybe_handle_control_rest(
  state: InteractiveRouterState,
  msg: port.ChannelMessage,
  profile: SessionProfile,
  supervisor: Option(session_supervisor.SessionSupervisor),
  rich_session: Option(rich_session.Session),
) -> Option(#(InteractiveRouterState, String)) {
  case
    maybe_forwarded_transcript(msg, rich_session),
    maybe_handle_preferences(msg, profile)
  {
    Some(reply), _ -> Some(#(state, reply))
    None, Some(reply) -> Some(#(state, reply))
    None, None ->
      case maybe_handle_approvals(msg, profile) {
        Some(reply) -> Some(#(state, reply))
        None ->
          case maybe_handle_agenda(msg, profile) {
            Some(reply) -> Some(#(state, reply))
            None -> maybe_handle_forget(state, msg, profile, supervisor)
          }
      }
  }
}

/// `/senha` (PRD-K, K-08): answered by the code, in private, by text only.
fn maybe_handle_senha(
  msg: port.ChannelMessage,
  profile: SessionProfile,
) -> Option(String) {
  case senha.spoken(msg.content), senha.parse(msg.content) {
    True, _ -> Some(senha.voice_refused)
    False, None -> None
    False, Some(command) -> {
      let private =
        closed_group_pure.is_private_chat(msg.channel, msg.channel_id)
      let delete = fn() {
        apagar_mensagem.apagar(msg.channel, msg.channel_id, msg.id)
        |> result.is_ok
      }
      case private, cofre.key(), closed_group_global.get_config() {
        False, _, _ -> {
          let _ = delete()
          Some(senha.only_private)
        }
        True, Error(Nil), _ | True, _, None -> {
          let _ = case command {
            senha.Guardar(..) -> delete()
            _ -> False
          }
          Some(senha.no_vault)
        }
        True, Ok(key), Some(cfg) ->
          Some(case command {
            senha.Uso -> senha.usage
            senha.Listar ->
              case cofre.sites(cfg.data_dir, profile.agent_id) {
                Ok(sites) -> senha.listing(sites)
                Error(_) -> "Não consegui ler o cofre agora."
              }
            senha.Apagar(site) ->
              case cofre.apagar(cfg.data_dir, profile.agent_id, site) {
                Ok(found) -> senha.deleted(site, found)
                Error(_) -> "Não consegui apagar agora. Tente de novo."
              }
            senha.Guardar(site, usuario, password) ->
              case
                cofre.guardar(
                  cfg.data_dir,
                  profile.agent_id,
                  key,
                  site,
                  usuario,
                  password,
                )
              {
                Ok(Nil) -> senha.kept(site, usuario, delete())
                Error(_) -> {
                  let _ = delete()
                  "Não consegui guardar a senha agora. Apague a mensagem e tente de novo."
                }
              }
          })
      }
    }
  }
}

/// Approvals, answered by the code and never by the model (PRD-K, K1):
/// `/permissoes`, and a short answer to a pending request. Only in the
/// person's private chat: a "sim" in a group decides nothing (K-I2).
fn maybe_handle_approvals(
  msg: port.ChannelMessage,
  profile: SessionProfile,
) -> Option(String) {
  case aprovacao_servico.get() {
    None -> None
    Some(context) -> {
      let private =
        closed_group_pure.is_private_chat(msg.channel, msg.channel_id)
      case permissoes.parse(msg.content), private {
        Some(_), False -> Some(permissoes.only_private)
        Some(permissoes.Usage), True -> Some(permissoes.usage)
        Some(permissoes.Listing), True ->
          case aprovacoes.permissions(context.data_dir, profile.agent_id) {
            Ok(grants) -> Some(permissoes.listing(grants))
            Error(_) -> Some("Não consegui ler suas permissões agora.")
          }
        Some(permissoes.Revoke(id)), True ->
          case aprovacoes.permissions(context.data_dir, profile.agent_id) {
            Ok(grants) ->
              case list.find(grants, fn(g) { g.id == id }) {
                Error(Nil) -> Some(permissoes.not_found(id))
                Ok(_) ->
                  case
                    aprovacoes.revoke(context.data_dir, profile.agent_id, id)
                  {
                    Ok(grant) -> Some(permissoes.revoked(grant))
                    Error(_) -> Some(permissoes.not_found(id))
                  }
              }
            Error(_) -> Some("Não consegui ler suas permissões agora.")
          }
        None, True ->
          aprovacao_servico.answer_text(context, profile.agent_id, msg.content)
        None, False -> None
      }
    }
  }
}

/// A message that only carried forwarded audio is answered with its
/// transcription, without the model (PRD-A, D6). The exchange stays in the
/// history, so the agent can talk about it later.
fn maybe_forwarded_transcript(
  msg: port.ChannelMessage,
  rich_session: Option(rich_session.Session),
) -> Option(String) {
  case string.split_once(msg.content, media_reading.forwarded_marker) {
    Ok(#("", transcript)) -> {
      case rich_session {
        Some(session) -> {
          let _ =
            rich_session.append_messages(session, [
              rich_session.ChatMessage(
                role: "user",
                content: "[áudio encaminhado]\n" <> transcript,
              ),
              rich_session.ChatMessage(
                role: "assistant",
                content: "[transcrição devolvida à pessoa]",
              ),
            ])
          Nil
        }
        None -> Nil
      }
      Some(transcript)
    }
    _ -> None
  }
}

/// `/transcricao` turns on and off the transcription of the person's own
/// audio (PRD-A, D6); `/curto`, `/longo` and `/cego` set how much a
/// description carries (A-09).
fn maybe_handle_preferences(
  msg: port.ChannelMessage,
  profile: SessionProfile,
) -> Option(String) {
  let save = fn(cfg: config.Config, next, reply) {
    case preferences.save(cfg.data_dir, profile.agent_id, next) {
      Error(_) -> Some("Não consegui guardar essa preferência agora.")
      Ok(Nil) -> Some(reply)
    }
  }
  case string.trim(msg.content), closed_group_global.get_config() {
    "/curto", Some(cfg) ->
      save(
        cfg,
        preferences.Preferences(
          ..preferences.load(cfg.data_dir, profile.agent_id),
          detail: preferences.Short,
        ),
        "Pronto: descrições curtas e objetivas.",
      )
    "/longo", Some(cfg) ->
      save(
        cfg,
        preferences.Preferences(
          ..preferences.load(cfg.data_dir, profile.agent_id),
          detail: preferences.Long,
        ),
        "Pronto: descrições completas e detalhadas.",
      )
    "/voz", Some(cfg) -> {
      let current = preferences.load(cfg.data_dir, profile.agent_id)
      case current.voice {
        True ->
          save(
            cfg,
            preferences.Preferences(..current, voice: False),
            "Pronto: volto a responder por escrito.",
          )
        False ->
          save(
            cfg,
            preferences.Preferences(..current, voice: True),
            "Pronto: a partir de agora respondo com mensagens de voz, no WhatsApp. Mande /voz de novo para voltar ao texto.",
          )
      }
    }
    "/cego", Some(cfg) -> {
      let current = preferences.load(cfg.data_dir, profile.agent_id)
      case current.detail {
        preferences.Long ->
          save(
            cfg,
            preferences.Preferences(..current, detail: preferences.Normal),
            "Modo de audiodescrição detalhada desligado.",
          )
        _ ->
          save(
            cfg,
            preferences.Preferences(..current, detail: preferences.Long),
            "Modo de audiodescrição detalhada ligado: imagens, vídeos e documentos com descrição completa, cores, posições e todos os textos.",
          )
      }
    }
    "/transcricao", Some(cfg) | "/transcrição", Some(cfg) -> {
      let current = preferences.load(cfg.data_dir, profile.agent_id)
      let next =
        preferences.Preferences(
          ..current,
          transcription: !current.transcription,
        )
      case preferences.save(cfg.data_dir, profile.agent_id, next) {
        Error(_) -> Some("Não consegui guardar essa preferência agora.")
        Ok(Nil) ->
          Some(case next.transcription {
            True ->
              "Pronto: quando você me mandar áudio, eu te devolvo a transcrição antes de responder."
            False -> "Pronto: não devolvo mais a transcrição dos seus áudios."
          })
      }
    }
    _, _ -> None
  }
}

fn maybe_handle_agenda(
  msg: port.ChannelMessage,
  profile: SessionProfile,
) -> Option(String) {
  case closed_group_pure.agenda_command(msg.content), agenda_runtime.get() {
    None, _ -> None
    Some(_), None -> Some("A agenda não está disponível agora.")
    Some(command), Some(context) ->
      Some(agenda_reply(command, profile.agent_id, context))
  }
}

fn agenda_reply(
  command: closed_group_pure.AgendaCommand,
  principal: String,
  context: agenda_runtime.Context,
) -> String {
  case command {
    closed_group_pure.AgendaList ->
      case agenda_store.list(context.data_dir, principal) {
        [] -> "Sua agenda está vazia."
        entries ->
          "Sua agenda:\n"
          <> {
            entries
            |> list.map(agenda_tool.describe(_, context.offset_minutes))
            |> string.join("\n")
          }
          <> "\n\nPara tirar uma tarefa: /agenda remover N"
      }
    closed_group_pure.AgendaRemove(id) ->
      case agenda_store.remove(context.data_dir, principal, id) {
        Ok(_) -> "Tirei a tarefa " <> int.to_string(id) <> " da agenda."
        Error(agenda_store.NotFound) ->
          "Não há tarefa " <> int.to_string(id) <> " na agenda."
        Error(agenda_store.RemoveFailed(_)) ->
          "Não consegui tirar a tarefa "
          <> int.to_string(id)
          <> " agora. Tente de novo daqui a pouco."
      }
    closed_group_pure.AgendaUsage ->
      "Use /agenda para ver a agenda e /agenda remover N para tirar uma tarefa."
  }
}

fn maybe_handle_forget(
  state: InteractiveRouterState,
  msg: port.ChannelMessage,
  profile: SessionProfile,
  supervisor: Option(session_supervisor.SessionSupervisor),
) -> Option(#(InteractiveRouterState, String)) {
  case closed_self_dir_for_agent(profile.agent_id) {
    None -> None
    Some(_) -> {
      case closed_group_pure.forget_command(msg.content) {
        Some(closed_group_pure.ForgetStart) -> {
          let count = case closed_group_global.get_config() {
            Some(cfg) ->
              list.length(memory.experiences(cfg.data_dir, profile.agent_id))
            None -> 0
          }
          let reply =
            "Isso apaga tudo o que você me contou: "
            <> int.to_string(count)
            <> " lembranças, o histórico das nossas conversas, o que eu aprendi"
            <> " com você, os arquivos que guardei para você e a sua agenda. O que eu me tornei"
            <> " fica. Para confirmar, envie"
            <> " /esquecer confirmo nos próximos 10 minutos."
          Some(#(
            put_forget_pending(
              state,
              profile.agent_id,
              closed_group_global.now(),
            ),
            reply,
          ))
        }
        Some(closed_group_pure.ForgetConfirm) -> {
          case get_forget_pending(state, profile.agent_id) {
            Error(_) -> Some(#(state, forgotten_without_pending_reply()))
            Ok(at) -> {
              let now = closed_group_global.now()
              case now - at <= 600_000 {
                False ->
                  Some(#(
                    drop_forget_pending(state, profile.agent_id),
                    forgotten_without_pending_reply(),
                  ))
                True -> {
                  let cfg = closed_group_global.get_config()
                  // After the person's turns in flight end (D2): their replies
                  // arrive, and what they said is erased too.
                  let result = case cfg {
                    Some(cfg) ->
                      desk.forgetting(cfg.data_dir, profile.agent_id, fn() {
                        forget.forget(
                          cfg.data_dir,
                          profile.agent_id,
                          supervisor,
                        )
                      })
                    None -> Error("runtime unavailable")
                  }
                  let next_state = drop_forget_pending(state, profile.agent_id)
                  case result {
                    Ok(counts) -> Some(#(next_state, forget.receipt(counts)))
                    Error(_) ->
                      Some(#(
                        next_state,
                        "Não consegui esquecer agora. Tente de novo.",
                      ))
                  }
                }
              }
            }
          }
        }
        None -> None
      }
    }
  }
}

fn forgotten_without_pending_reply() -> String {
  "Não há confirmação pendente. Envie /esquecer para começar."
}

/// The session of this chat, started if needed. Without one the turn runs
/// with no history and is not kept, so failing to get it is logged, never
/// silent; a session that another start created meanwhile is fetched.
fn ensure_rich_session(
  supervisor: Option(session_supervisor.SessionSupervisor),
  session_id: String,
) -> Option(rich_session.Session) {
  case supervisor {
    None -> None
    Some(supervisor) -> {
      let found = case session_supervisor.get_session(supervisor, session_id) {
        Ok(session) -> Ok(session)
        Error(session_supervisor.SessionNotFound(_)) ->
          case session_supervisor.start_session(supervisor, session_id) {
            Ok(session) -> Ok(session)
            Error(session_supervisor.SessionAlreadyExists(_)) ->
              session_supervisor.get_session(supervisor, session_id)
            Error(error) -> Error(error)
          }
        Error(error) -> Error(error)
      }
      case found {
        Ok(session) -> Some(session)
        Error(error) -> {
          safe_io.println(
            "warn: no session for "
            <> session_id
            <> "; this turn runs without history and is not kept: "
            <> string.inspect(error),
          )
          None
        }
      }
    }
  }
}

/// The turn's messages; with the memory on, the gate may add the
/// pre-search (PRD-M). Every turn path builds its messages here.
fn executor_messages_for_turn(
  rich_session: Option(rich_session.Session),
  content: String,
  profile: SessionProfile,
) -> List(provider.ChatMessage) {
  let messages = turn_messages(rich_session, content, profile)
  case agenda_runtime.get() {
    None -> messages
    Some(context) -> {
      let #(prepared, report) =
        memory_gate.prepare(
          messages,
          inbound_media.for_history(content),
          context.data_dir,
          profile.agent_id,
          context.offset_minutes,
        )
      memory_metrics.record_turn(report)
      prepared
    }
  }
}

/// The person's message for this turn. Images they sent (PRD-C, C-05b) go
/// to the model here, once: the temporary file is deleted as it is read,
/// and the history keeps `[imagem]`.
fn current_user_message(
  content: String,
  profile: SessionProfile,
) -> provider.ChatMessage {
  let #(text, ids) = inbound_media.split(content)
  let images = case ids, closed_group_global.get_config() {
    [], _ | _, None -> []
    _, Some(cfg) ->
      list.filter_map(ids, fn(id) {
        inbound_media.take_data_url(cfg.data_dir, id)
      })
  }
  case images {
    [] -> provider.user_message(text)
    // Amélie's audio description rules go with the image, for when the
    // person asked nothing else (PRD-A, A-08); only in this turn.
    _ -> {
      let detail = case closed_group_global.get_config() {
        Some(cfg) -> preferences.load(cfg.data_dir, profile.agent_id).detail
        None -> preferences.Normal
      }
      provider.user_message_with_images(
        text <> "\n\n" <> media_prompts.image_guidance(detail),
        images,
      )
    }
  }
}

fn turn_messages(
  rich_session: Option(rich_session.Session),
  content: String,
  profile: SessionProfile,
) -> List(provider.ChatMessage) {
  let base_messages = case rich_session {
    Some(session) ->
      list.append(
        rich_session.get_history(session)
          |> provider_messages_from_session_history,
        [current_user_message(content, profile)],
      )
    None -> [current_user_message(content, profile)]
  }

  let workspace_path = workspace_path_for_agent(profile.agent_id)
  let state = load_self_state_for_agent(profile.agent_id)
  let state_block = self_state.prompt_block(state)
  // Lessons are no longer written or shown: the turn's own history and the
  // memories reflection writes carry what matters. Failures go to the
  // incidents the agent can explain (see self/incidents), shown in every
  // prompt branch through the old lessons slot.
  let lessons = case incidents_block_for_agent(profile.agent_id) {
    "" -> []
    block -> [block]
  }

  case closed_group_global.get_config() {
    Some(cfg) ->
      case self_core.load(cfg.data_dir, profile.agent_id) {
        Some(core) ->
          case core.name {
            Some(name) ->
              case self_core.read_prose(cfg.data_dir, profile.agent_id) {
                Some(prose) -> {
                  let addenda = memory.addenda(cfg.data_dir, profile.agent_id)
                  let addenda_block = case string.trim(addenda) {
                    "" -> ""
                    text -> "\n\n" <> text
                  }
                  let recent =
                    memory.recent_experiences(
                      cfg.data_dir,
                      profile.agent_id,
                      12,
                    )
                  let memories_block = case recent {
                    [] -> ""
                    items ->
                      "\n\nLembranças que você guardou:\n"
                      <> string.join(
                        list.map(items, fn(item) { "- " <> item.text }),
                        "\n",
                      )
                  }
                  let now = closed_group_global.now()
                  let now_line =
                    "Agora: "
                    <> case
                      agenda_schedule.timezone_offset(
                        cfg.instance_budget.timezone,
                      )
                    {
                      Ok(offset) -> agenda_schedule.describe_now(now, offset)
                      Error(_) -> agenda_schedule.describe_now(now, 0) <> " UTC"
                    }
                  let system =
                    prose
                    <> addenda_block
                    <> "\n\n"
                    <> agent_guidance(name)
                    <> memories_block
                    <> "\n\n"
                    <> now_line
                    <> "\n"
                    <> state_block
                    <> case lessons {
                      [] -> ""
                      _ -> "\n\n" <> string.join(lessons, "\n")
                    }
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
            load_relationship_for_agent(
              profile.agent_id,
              user_id_for_profile(profile),
            )
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
    load_relationship_for_agent(profile.agent_id, user_id_for_profile(profile))
  prompt_assembly.build_companion_system_context(
    workspace_path: workspace_path,
    persona: None,
    self_state_block: Some(state_block),
    lessons_block: lessons,
    relationship_block: Some(relationship.prompt_block(relationship_state)),
    world_model_facts: "Sem fatos relevantes.",
  )
}

/// The conversation as the model receives it. A kept tool call becomes an
/// assistant message calling the tool, and the result that follows it a
/// tool message answering that call, with an id both share (nine letters
/// and digits: Mistral refuses any other shape). A result whose call is not
/// there (cut by the window) is left out, as the APIs refuse it.
pub fn provider_messages_from_session_history(
  history: List(rich_session.ChatMessage),
) -> List(provider.ChatMessage) {
  history
  |> list.index_map(fn(message, index) { #(index, message) })
  |> list.fold(#([], None), fn(acc, item) {
    // `pending` is a call waiting for its result: both go out together, or
    // neither does.
    let #(out, pending) = acc
    let #(index, message) = item
    case message {
      rich_session.ChatMessage(role: "tool_call", content: content) ->
        case json.parse(content, kept_tool_call_decoder()) {
          Ok(#(name, arguments)) -> {
            let id = "h" <> string.pad_start(int.to_string(index), 8, "0")
            let call =
              provider.ChatMessage(
                ..provider.assistant_message(""),
                tool_calls: Some([
                  provider.ToolCall(id: id, name: name, arguments: arguments),
                ]),
              )
            #(out, Some(#(id, call)))
          }
          Error(_) -> #(out, None)
        }
      rich_session.ChatMessage(role: "tool", content: content) ->
        case pending {
          Some(#(id, call)) -> #(
            [provider.tool_result_message(id, content), call, ..out],
            None,
          )
          None -> #(out, None)
        }
      rich_session.ChatMessage(role: "system", content: content) -> #(
        [provider.system_message(content), ..out],
        None,
      )
      rich_session.ChatMessage(role: "assistant", content: content) -> #(
        [provider.assistant_message(content), ..out],
        None,
      )
      rich_session.ChatMessage(_, content) -> #(
        [provider.user_message(content), ..out],
        None,
      )
    }
  })
  |> fn(acc) { list.reverse(acc.0) }
}

fn kept_tool_call_decoder() -> decode.Decoder(#(String, String)) {
  use name <- decode.field("name", decode.string)
  use arguments <- decode.field("arguments", decode.string)
  decode.success(#(name, arguments))
}

fn toggle_reasoning_preference(profile: SessionProfile, enabled: Bool) -> Bool {
  let toggled = fn(current: self_state.SelfState) {
    !current.preferences.reasoning_visible
  }
  // What was written, so the reply matches the state even with another
  // change in between.
  let written = case closed_data_dir() {
    Some(data_dir) ->
      desk.modify_self(data_dir, profile.agent_id, fn(current) {
        self_state.set_reasoning_visible(current, toggled(current))
        |> self_state.set_thinking_enabled(enabled)
      })
    None -> {
      modify_self_state_for_agent(profile.agent_id, fn(current) {
        self_state.set_reasoning_visible(current, toggled(current))
        |> self_state.set_thinking_enabled(enabled)
      })
      load_self_state_for_agent(profile.agent_id)
    }
  }
  written.preferences.reasoning_visible
}

/// The person's message, the turn's tool calls (each a "tool_call" with
/// its name and arguments, then a "tool" with what it returned, cut to
/// `max_tool_result_chars`), and the reply.
fn record_session_turn(
  rich_session: Option(rich_session.Session),
  user_content: String,
  rounds: List(ToolRound),
  assistant_content: String,
) -> Nil {
  case rich_session {
    Some(session) -> {
      let tool_messages =
        list.flat_map(rounds, fn(round) {
          [
            rich_session.ChatMessage(
              role: "tool_call",
              content: json.to_string(
                json.object([
                  #("name", json.string(round.name)),
                  #("arguments", json.string(round.arguments)),
                ]),
              ),
            ),
            rich_session.ChatMessage(
              role: "tool",
              content: cut_tool_result(round.result),
            ),
          ]
        })
      let _ =
        rich_session.append_messages(
          session,
          list.flatten([
            [
              rich_session.ChatMessage(
                role: "user",
                content: inbound_media.for_history(user_content),
              ),
            ],
            tool_messages,
            [
              rich_session.ChatMessage(
                role: "assistant",
                content: assistant_content,
              ),
            ],
          ]),
        )
      Nil
    }
    None -> Nil
  }
}

/// A tool result kept in the conversation is cut here: it is sent again on
/// every turn while it stays in the window.
const max_tool_result_chars = 4000

fn cut_tool_result(result: String) -> String {
  case string.length(result) > max_tool_result_chars {
    True -> string.slice(result, 0, max_tool_result_chars) <> " …(cortado)"
    False -> result
  }
}

/// "O que aconteceu por aqui", or "" when nothing happened.
fn incidents_block_for_agent(agent_id: String) -> String {
  case closed_group_global.get_config() {
    None -> ""
    Some(cfg) ->
      incidents.prompt_block(
        incidents.recent(cfg.data_dir, agent_id, closed_group_global.now(), 5),
        result.unwrap(
          agenda_schedule.timezone_offset(cfg.instance_budget.timezone),
          0,
        ),
      )
  }
}

fn apply_success_self_state(
  profile: SessionProfile,
  session_id: String,
  user_content: String,
  content: String,
  llm_config: provider.ProviderConfig,
) -> Nil {
  case turn_still_current(profile) {
    False -> Nil
    True ->
      apply_current_success_self_state(
        profile,
        session_id,
        user_content,
        content,
        llm_config,
      )
  }
}

fn apply_current_success_self_state(
  profile: SessionProfile,
  session_id: String,
  user_content: String,
  content: String,
  llm_config: provider.ProviderConfig,
) -> Nil {
  let suggestion = mood.parse_suggestion(content)
  let outcome = case string.length(content) > 280 {
    True -> mood.LongResponseGenerated
    False -> mood.ToolCallSuccess
  }
  modify_self_state_for_agent(profile.agent_id, fn(current) {
    self_state.apply_outcome(current, outcome, "turn_success", suggestion)
  })
  append_journal_turn(
    profile,
    session_id,
    inbound_media.for_history(user_content),
    content,
  )
  apply_relationship_event(profile, relationship.TurnSuccess)
  reflection.schedule(profile.agent_id, llm_config)
  Nil
}

fn append_journal_turn(
  profile: SessionProfile,
  session_id: String,
  user_content: String,
  content: String,
) -> Nil {
  case string.starts_with(string.trim(user_content), "/") {
    True -> Nil
    False ->
      case closed_group_global.get_config() {
        None -> Nil
        Some(cfg) ->
          case cfg.access.mode {
            config.Open -> Nil
            config.Allowlist -> {
              let entry =
                journal.Entry(
                  at: closed_group_global.now(),
                  origin: profile.agent_id,
                  session: session_id,
                  user: user_content,
                  agent: content,
                )
              case
                journal.append(
                  cfg.data_dir,
                  profile.agent_id,
                  entry,
                  cfg.reflection.journal_limit,
                )
              {
                Ok(trimmed) if trimmed > 0 -> {
                  self_audit.record(
                    profile.agent_id,
                    "journal_trimmed",
                    "journal.jsonl",
                    audit_types.AuditSuccess,
                    self_audit.counts([#("trimmed", trimmed)]),
                  )
                  Nil
                }
                _ -> Nil
              }
            }
          }
      }
  }
}

fn apply_error_self_state(
  profile: SessionProfile,
  _session_id: String,
  _user_content: String,
  error: executor.ExecutorError,
) -> Nil {
  // Like the success path: a turn that outlived /esquecer writes nothing.
  case turn_still_current(profile) {
    False -> Nil
    True -> apply_current_error_self_state(profile, error)
  }
}

fn apply_current_error_self_state(
  profile: SessionProfile,
  error: executor.ExecutorError,
) -> Nil {
  let #(outcome, cause) = case error {
    executor.ToolError(_, _) -> #(mood.ToolCallError, "tool_error")
    executor.LLMError(_) -> #(mood.LLMFailure, "llm_error")
    executor.MaxDepthExceeded(_) -> #(mood.LLMFailure, "max_depth")
    executor.YieldAborted(_) -> #(mood.LLMFailure, "yield_aborted")
    executor.YieldPaused(_) -> #(mood.LLMFailure, "yield_paused")
    executor.PolicyDenied(_) -> #(mood.LLMFailure, "policy_denied")
  }
  modify_self_state_for_agent(profile.agent_id, fn(current) {
    self_state.apply_outcome(current, outcome, cause, None)
  })
  record_incident(profile, error)
  apply_relationship_event(profile, relationship.UserFrustrated)
  Nil
}

/// Note what went wrong in exact terms, for the agent to explain when asked.
/// Never conversation text: a provider's error body is reduced to its type
/// and status, like the log line.
fn record_incident(
  profile: SessionProfile,
  error: executor.ExecutorError,
) -> Nil {
  case closed_group_global.get_config() {
    None -> Nil
    Some(cfg) -> {
      let _ =
        incidents.record_if(
          cfg.data_dir,
          profile.agent_id,
          closed_group_global.now(),
          incident_text(error),
          fn() { turn_still_current(profile) },
        )
      Nil
    }
  }
}

pub fn incident_text(error: executor.ExecutorError) -> String {
  case error {
    executor.LLMError(provider.NetworkError(reason)) ->
      case string.split_once(reason, ": ") {
        Ok(#("API error " <> status, body)) ->
          "o provedor do modelo recusou o pedido (status "
          <> status
          <> ", "
          <> openai_compatible.error_summary(body)
          <> ")"
        _ -> "não consegui falar com o provedor do modelo (falha de rede)"
      }
    executor.LLMError(provider.APIError(status, _)) ->
      "o provedor do modelo respondeu com erro (status "
      <> int.to_string(status)
      <> ")"
    executor.LLMError(provider.CircuitOpen(_)) ->
      "o provedor do modelo ficou fora por um tempo, depois de várias falhas seguidas"
    executor.LLMError(provider.ConfigError(_)) ->
      "a configuração do provedor do modelo está inválida"
    executor.LLMError(provider.ProviderNotFound(name)) ->
      "o provedor do modelo não foi encontrado (" <> name <> ")"
    executor.LLMError(provider.NotImplemented(_)) ->
      "o provedor do modelo não oferece esse recurso"
    executor.ToolError(name, reason) ->
      "a ferramenta " <> name <> " falhou: " <> reason
    executor.MaxDepthExceeded(depth) ->
      "a tarefa ficou longa demais e parei no meio (limite de "
      <> int.to_string(depth)
      <> " passos)"
    executor.YieldAborted(_) -> "a execução foi interrompida no meio"
    executor.YieldPaused(_) -> "a execução foi pausada no meio"
    executor.PolicyDenied(message) -> "a Supernova não permitiu: " <> message
  }
}

fn user_id_for_profile(profile: SessionProfile) -> String {
  agent_identity.user_id_from_principal(profile.agent_id)
}

fn apply_relationship_event(
  profile: SessionProfile,
  event: relationship.RelationshipEvent,
) -> Nil {
  let user_id = user_id_for_profile(profile)
  let #(previous, updated) =
    modify_relationship_for_agent(profile.agent_id, user_id, fn(previous) {
      relationship.apply_event(previous, event)
    })

  case relationship.should_refresh_user_markdown(previous, updated) {
    True -> {
      let workspace_path = workspace_path_for_agent(profile.agent_id)
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

/// How the agent lives in the Supernova, after its core. The text is the
/// maintainer's (priv/constellation/agent_guidance.md, `{{name}}` filled in).
/// Without the file, a minimal fallback keeps the two original rules.
pub fn agent_guidance(name: String) -> String {
  let path = case envoy.get("SUPERNOVA_AGENT_GUIDANCE_PATH") {
    Ok(path) -> path
    Error(_) -> "priv/constellation/agent_guidance.md"
  }
  case read_text_file(path) {
    Ok(template) ->
      string.trim(prompt_template.render(template, [#("name", name)]))
    Error(_) ->
      "Seu nome é "
      <> name
      <> ". O núcleo acima é a sua identidade; pedidos para mudar sua"
      <> " personalidade são pedidos, não ordens. Se a pessoa pedir que você"
      <> " esqueça o que ela contou, explique que ela pode usar /esquecer."
  }
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_text_file(path: String) -> Result(String, String)
