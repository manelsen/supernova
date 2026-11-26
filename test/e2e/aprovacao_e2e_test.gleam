//// PRD-K, K-02: a request for approval, answered through the router as a
//// person answers it. The code decides; the model never sees the answer.

import e2e/e2e_support as support
import envoy
import exception
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/channel_router
import supernova/aprovacao/servico
import supernova/channel/port
import supernova/config
import supernova/core/session/history_store
import supernova/core/session/supervisor as session_supervisor
import supernova/llm/provider
import supernova/self/aprovacoes.{Draft, ForTask, Send}
import supernova/tools/computador as computador_tool

fn cfg() -> config.Config {
  config.Config(
    ..support.channel_config(),
    access: config.AccessConfig(
      ..support.access_config([], ["sim:carol"]),
      allowed_chats: ["sim:grupo-1"],
    ),
  )
}

fn say(
  router: channel_router.ChannelRouter,
  chat_id: String,
  content: String,
) -> String {
  let events = process.new_subject()
  let message =
    port.ChannelMessage(
      id: chat_id <> "-" <> content,
      channel: "sim",
      channel_id: chat_id,
      user_id: "carol",
      username: "carol",
      content: content,
      is_bot: False,
      reply_to_id: None,
    )
  case
    channel_router.route_inbound_for_handler(
      router,
      port.InboundMessage(message),
      events,
    )
  {
    Ok(port.ImmediateReply(reply)) -> reply.content
    Ok(port.StreamReply(_)) -> await_stream(events)
    other -> "UNEXPECTED " <> string.inspect(other)
  }
}

fn press(router: channel_router.ChannelRouter, action: String) -> String {
  let events = process.new_subject()
  let interaction =
    port.ChannelInteractionMessage(
      channel: "sim",
      channel_id: "dm-carol",
      user_id: "carol",
      username: "carol",
      is_bot: False,
      event: port.ChannelInteractionEvent(
        id: "i-" <> action,
        action_id: action,
        values: [],
        source_message_id: Some("m1"),
      ),
    )
  case
    channel_router.route_inbound_for_handler(
      router,
      port.InboundInteraction(interaction),
      events,
    )
  {
    Ok(port.ImmediateReply(reply)) -> reply.content
    other -> "UNEXPECTED " <> string.inspect(other)
  }
}

fn await_stream(events: process.Subject(port.ChannelStreamEvent)) -> String {
  case process.receive(events, 5000) {
    Ok(port.StreamComplete(reply)) -> reply.content
    Ok(port.StreamUpdate(_)) -> await_stream(events)
    Ok(port.StreamFailure(_)) | Error(_) -> ""
  }
}

fn draft(target: String) {
  Draft(
    kind: Send,
    target: target,
    summary: "Usar o site " <> target <> " nesta tarefa.",
    explanation: "Para ver os horários.",
    task: Some(1),
    approve: ForTask,
    always: True,
    origin: aprovacoes.Chat("sim", "grupo-1", "carol"),
  )
}

fn drain(sent: Subject(a)) -> List(a) {
  case process.receive(sent, 0) {
    Ok(item) -> [item, ..drain(sent)]
    Error(Nil) -> []
  }
}

pub fn an_approval_is_answered_by_the_code_in_private_only_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() {
    envoy.unset("SUPERNOVA_CONSTELLATION_PATH")
    servico.clear()
  })
  support.with_runtime_root(cfg(), fn(root) {
    let llm =
      provider.ProviderConfig(
        name: "mock",
        api_key: None,
        base_url: None,
        default_model: "mock-model",
      )
    let private_sent = process.new_subject()
    let injected = process.new_subject()
    let context =
      servico.Context(
        data_dir: root,
        clock: fn() { 1000 },
        send_private: fn(principal, text, _) {
          process.send(private_sent, #(principal, text))
          Ok(Nil)
        },
        inject: fn(message) {
          process.send(injected, message)
          Ok(Nil)
        },
      )
    servico.configure(context)
    let store = history_store.HistoryStore(data_dir: root, limit: 40)
    let assert Ok(sessions) = session_supervisor.start_with_history(store)
    let assert Ok(router) =
      channel_router.start_with_session_supervisor("sim", sessions, llm)

    // Carol meets her agent in private.
    let _ = say(router, "dm-carol", "oi")
    let _ = say(router, "dm-carol", "Lua")
    let _ = say(router, "dm-carol", "sim")

    let assert Ok(_) =
      servico.pedir(context, "sim:carol", draft("a.com"), in_group: True)
    let assert Ok(_) =
      servico.pedir(context, "sim:carol", draft("b.com"), in_group: True)
    let assert [#("sim:carol", _), #("sim:carol", _)] = drain(private_sent)

    // In the group, "sim 1" decides nothing: it goes to the agent (K-I2).
    say(router, "grupo-1", "sim 1") |> should.equal("Mock response")
    let assert Ok([_, _]) = aprovacoes.pending(root, "sim:carol")

    // In private, a bare answer with two pending asks which.
    let which = say(router, "dm-carol", "sim")
    string.contains(which, "número") |> should.be_true

    // A spoken answer with the number decides, without the model.
    clear_prompts()
    let reply =
      say(router, "dm-carol", "[mensagem de voz de 1 s, transcrita]\nSim, um.")
    string.starts_with(reply, "Aprovado") |> should.be_true
    prompt_texts() |> should.equal([])
    let assert [outcome] = drain(injected)
    outcome.channel_id |> should.equal("grupo-1")
    string.starts_with(outcome.content, "[Aprovação 1] aprovada")
    |> should.be_true

    // The button for "always" makes a permanent permission.
    let pressed = press(router, "aprovacao:2:sempre")
    string.starts_with(pressed, "Aprovado") |> should.be_true
    let listing = say(router, "dm-carol", "/permissoes")
    string.contains(listing, "b.com") |> should.be_true
    say(router, "grupo-1", "/permissoes")
    |> string.contains("privado")
    |> should.be_true

    let assert Ok([permission]) = aprovacoes.permissions(root, "sim:carol")
    let revoked =
      say(router, "dm-carol", "/permissoes revogar " <> int(permission.id))
    string.starts_with(revoked, "Revogada") |> should.be_true
    aprovacoes.permissions(root, "sim:carol") |> should.equal(Ok([]))

    // With nothing pending, "sim" is just a message for the agent.
    say(router, "dm-carol", "sim") |> should.equal("Mock response")
    list.length(drain(injected)) |> should.equal(1)
    session_supervisor.stop(sessions)
  })
}

fn int(value: Int) -> String {
  string.inspect(value)
}

@external(erlang, "supernova_mock_ffi", "clear_prompts")
fn clear_prompts() -> Nil

@external(erlang, "supernova_mock_ffi", "prompts")
fn prompt_texts() -> List(String)

/// PRD-K, K-05 (K21): the agent asks for a site for the shell; the person
/// says yes; the site is on their list for good.
pub fn a_site_for_the_shell_is_asked_and_approved_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  // The tool is offered only with a computer configured; nothing is called.
  let _ = envoy.set("SUPERNOVA_COMPUTER_URL", "http://127.0.0.1:9")
  use <- exception.defer(fn() {
    envoy.unset("SUPERNOVA_CONSTELLATION_PATH")
    envoy.unset("SUPERNOVA_COMPUTER_URL")
    servico.clear()
  })
  let admin_cfg =
    config.Config(
      ..support.channel_config(),
      access: config.AccessConfig(
        ..support.access_config(["sim:carol"], []),
        allowed_chats: [],
      ),
    )
  support.with_runtime_root(admin_cfg, fn(root) {
    let llm =
      provider.ProviderConfig(
        name: "mock",
        api_key: None,
        base_url: None,
        default_model: "mock-model",
      )
    let private_sent = process.new_subject()
    let context =
      servico.Context(
        data_dir: root,
        clock: fn() { 1000 },
        send_private: fn(principal, text, _) {
          process.send(private_sent, #(principal, text))
          Ok(Nil)
        },
        inject: fn(_) { Ok(Nil) },
      )
    servico.configure(context)
    let store = history_store.HistoryStore(data_dir: root, limit: 40)
    let assert Ok(sessions) = session_supervisor.start_with_history(store)
    let assert Ok(router) =
      channel_router.start_with_session_supervisor("sim", sessions, llm)
    let _ = say(router, "dm-carol", "oi")
    let _ = say(router, "dm-carol", "Lua")
    let _ = say(router, "dm-carol", "sim")

    let answer =
      say(router, "dm-carol", "instala a lib [mock-site Exemplo.com]")
    let sent = drain(private_sent)
    case sent {
      [_] -> Nil
      _ -> panic as { "nothing asked; the turn said: " <> answer }
    }
    let assert [#("sim:carol", text)] = sent
    // The first sentence is the code's, from the real site.
    string.starts_with(
      text,
      "Liberar o site exemplo.com para o shell do seu computador baixar arquivos.",
    )
    |> should.be_true
    string.contains(text, "Para instalar a biblioteca.") |> should.be_true

    let reply = say(router, "dm-carol", "sim")
    string.starts_with(reply, "Aprovado") |> should.be_true
    computador_tool.shell_sites("sim:carol") |> should.equal(["exemplo.com"])
    session_supervisor.stop(sessions)
  })
}

type FakeComputer

@external(erlang, "mcp_computer_fake_ffi", "start")
fn start_computer(responder: fn(String) -> #(Int, String)) -> FakeComputer

@external(erlang, "mcp_computer_fake_ffi", "requests")
fn computer_requests(fake: FakeComputer) -> List(String)

@external(erlang, "mcp_computer_fake_ffi", "stop")
fn stop_computer(fake: FakeComputer) -> Nil

@external(erlang, "erlang", "element")
fn computer_port(index: Int, fake: FakeComputer) -> Int

/// PRD-K, K-06: the browser gate refuses a send; the person is asked with
/// what would go; a yes lets the next try through once, and is spent.
pub fn a_send_the_gate_refused_is_asked_and_spent_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  // The computer: refuses the send unless the call allows it; then uses it.
  let fake = start_computer(fun_computer)
  let _ =
    envoy.set(
      "SUPERNOVA_COMPUTER_URL",
      "http://127.0.0.1:" <> string.inspect(computer_port(1, fake)),
    )
  use <- exception.defer(fn() {
    envoy.unset("SUPERNOVA_CONSTELLATION_PATH")
    envoy.unset("SUPERNOVA_COMPUTER_URL")
    stop_computer(fake)
    servico.clear()
  })
  let admin_cfg =
    config.Config(
      ..support.channel_config(),
      access: config.AccessConfig(
        ..support.access_config(["sim:carol"], []),
        allowed_chats: [],
      ),
    )
  support.with_runtime_root(admin_cfg, fn(root) {
    let llm =
      provider.ProviderConfig(
        name: "mock",
        api_key: None,
        base_url: None,
        default_model: "mock-model",
      )
    let private_sent = process.new_subject()
    let context =
      servico.Context(
        data_dir: root,
        clock: fn() { 1000 },
        send_private: fn(principal, text, _) {
          process.send(private_sent, #(principal, text))
          Ok(Nil)
        },
        inject: fn(_) { Ok(Nil) },
      )
    servico.configure(context)
    let store = history_store.HistoryStore(data_dir: root, limit: 40)
    let assert Ok(sessions) = session_supervisor.start_with_history(store)
    let assert Ok(router) =
      channel_router.start_with_session_supervisor("sim", sessions, llm)
    let _ = say(router, "dm-carol", "oi")
    let _ = say(router, "dm-carol", "Lua")
    let _ = say(router, "dm-carol", "sim")

    let _ = say(router, "dm-carol", "marca a consulta [mock-clique #enviar]")
    let assert [#("sim:carol", text)] = drain(private_sent)
    // The first sentence is the code's, from what the gate saw.
    string.starts_with(
      text,
      "Enviar o formulário em saude.gov.br: nome = Carol; senha = ••••.",
    )
    |> should.be_true

    let reply = say(router, "dm-carol", "sim")
    string.starts_with(reply, "Aprovado") |> should.be_true
    // The next click carries the yes, the computer uses it, it is spent.
    let _ = say(router, "dm-carol", "de novo [mock-clique #enviar]")
    drain(private_sent) |> should.equal([])
    let clicks =
      computer_requests(fake)
      |> list.filter(fn(raw) { string.contains(raw, "\"op\":\"click\"") })
    let assert [first, second] = clicks
    string.contains(first, "\"envios\":[]") |> should.be_true
    string.contains(second, "\"envios\":[\"saude.gov.br\"]") |> should.be_true
    let assert Ok([]) =
      aprovacoes.valid_grants(root, "sim:carol", 2000, aprovacoes.Send, None)
    session_supervisor.stop(sessions)
  })
}

fn fun_computer(body: String) -> #(Int, String) {
  case string.contains(body, "\"envios\":[\"saude.gov.br\"]") {
    True -> #(
      200,
      "{\"ok\":true,\"url\":\"https://saude.gov.br/\",\"title\":\"Marcado\",\"portao\":{\"recusas\":[],\"usados\":[\"saude.gov.br\"]}}",
    )
    False -> #(
      200,
      "{\"ok\":true,\"url\":\"https://saude.gov.br/\",\"title\":\"Form\",\"clicado\":false,\"portao\":{\"recusas\":[{\"tipo\":\"envio\",\"site\":\"saude.gov.br\",\"metodo\":\"POST\",\"campos\":\"nome = Carol; senha = ••••\",\"botao\":\"Enviar\"}],\"usados\":[]}}",
    )
  }
}

/// PRD-K, K-07 (K22): overwriting a person's file asks; a yes lets it
/// through once.
pub fn overwriting_a_file_asks_and_the_yes_is_spent_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  let fake = start_computer(file_computer)
  let _ =
    envoy.set(
      "SUPERNOVA_COMPUTER_URL",
      "http://127.0.0.1:" <> string.inspect(computer_port(1, fake)),
    )
  use <- exception.defer(fn() {
    envoy.unset("SUPERNOVA_CONSTELLATION_PATH")
    envoy.unset("SUPERNOVA_COMPUTER_URL")
    stop_computer(fake)
    servico.clear()
  })
  let admin_cfg =
    config.Config(
      ..support.channel_config(),
      access: config.AccessConfig(
        ..support.access_config(["sim:carol"], []),
        allowed_chats: [],
      ),
    )
  support.with_runtime_root(admin_cfg, fn(root) {
    let llm =
      provider.ProviderConfig(
        name: "mock",
        api_key: None,
        base_url: None,
        default_model: "mock-model",
      )
    let private_sent = process.new_subject()
    servico.configure(
      servico.Context(
        data_dir: root,
        clock: fn() { 1000 },
        send_private: fn(principal, text, _) {
          process.send(private_sent, #(principal, text))
          Ok(Nil)
        },
        inject: fn(_) { Ok(Nil) },
      ),
    )
    let store = history_store.HistoryStore(data_dir: root, limit: 40)
    let assert Ok(sessions) = session_supervisor.start_with_history(store)
    let assert Ok(router) =
      channel_router.start_with_session_supervisor("sim", sessions, llm)
    let _ = say(router, "dm-carol", "oi")
    let _ = say(router, "dm-carol", "Lua")
    let _ = say(router, "dm-carol", "sim")

    let _ =
      say(
        router,
        "dm-carol",
        "reescreve [mock-arquivo /home/pwuser/trabalho/nota.txt]",
      )
    let assert [#("sim:carol", text)] = drain(private_sent)
    string.starts_with(
      text,
      "Sobrescrever o arquivo /home/pwuser/trabalho/nota.txt com um texto novo.",
    )
    |> should.be_true
    let _ = say(router, "dm-carol", "sim")
    let _ =
      say(
        router,
        "dm-carol",
        "de novo [mock-arquivo /home/pwuser/trabalho/nota.txt]",
      )
    let writes =
      computer_requests(fake)
      |> list.filter(fn(raw) { string.contains(raw, "\"op\":\"write_file\"") })
    let assert [_, second] = writes
    string.contains(second, "\"arquivos\":[\"/home/pwuser/trabalho/nota.txt\"]")
    |> should.be_true
    let assert Ok([]) =
      aprovacoes.valid_grants(
        root,
        "sim:carol",
        2000,
        aprovacoes.Overwrite,
        None,
      )
    session_supervisor.stop(sessions)
  })
}

fn file_computer(body: String) -> #(Int, String) {
  case
    string.contains(body, "\"arquivos\":[\"/home/pwuser/trabalho/nota.txt\"]")
  {
    True -> #(
      200,
      "{\"ok\":true,\"path\":\"/home/pwuser/trabalho/nota.txt\",\"bytes\":10,\"portao\":{\"recusas\":[],\"usados\":[\"/home/pwuser/trabalho/nota.txt\"]}}",
    )
    False -> #(
      200,
      "{\"ok\":true,\"path\":\"/home/pwuser/trabalho/nota.txt\",\"gravado\":false,\"portao\":{\"recusas\":[{\"tipo\":\"arquivo\",\"acao\":\"sobrescrever\",\"caminho\":\"/home/pwuser/trabalho/nota.txt\",\"bytes\":8,\"novos\":10}],\"usados\":[]}}",
    )
  }
}
