import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import supernova/aprovacao/servico
import supernova/channel/port
import supernova/self/aprovacoes.{Draft, ForTask, Once, Send}
import test_workspace

const hour = 3_600_000

type Sent {
  Private(principal: String, text: String, buttons: Bool)
  Injected(port.ChannelMessage)
}

fn context(
  name: String,
  now: fn() -> Int,
) -> #(servico.Context, Subject(Sent)) {
  let sent = process.new_subject()
  let context =
    servico.Context(
      data_dir: test_workspace.create_temp_dir("servico_" <> name),
      clock: now,
      send_private: fn(principal, text, buttons: Option(_)) {
        process.send(sent, Private(principal, text, option.is_some(buttons)))
        Ok(Nil)
      },
      inject: fn(message) {
        process.send(sent, Injected(message))
        Ok(Nil)
      },
    )
  #(context, sent)
}

fn drain(sent: Subject(Sent)) -> List(Sent) {
  case process.receive(sent, 0) {
    Ok(item) -> [item, ..drain(sent)]
    Error(Nil) -> []
  }
}

fn draft(target: String, approve) {
  Draft(
    kind: Send,
    target: target,
    summary: "Enviar o formulário em " <> target <> ".",
    explanation: "Para marcar a consulta.",
    task: Some(4),
    approve: approve,
    always: False,
    origin: aprovacoes.Chat("telegram", "-200", "100"),
  )
}

fn clock(start: Int) -> #(fn() -> Int, fn(Int) -> Nil) {
  let key = "servico_test_clock"
  put(key, start)
  #(fn() { get(key) }, fn(value) { put(key, value) })
}

pub fn a_request_goes_to_the_private_chat_once_test() {
  let #(now, _) = clock(0)
  let #(context, sent) = context("privado", now)
  let assert Ok(note) =
    servico.pedir(context, "telegram:100", draft("a.com", Once), in_group: True)
  // The agent is told to wait, and that the group only hears a notice (K9).
  string.contains(note, "Pedi aprovação (1)") |> should.be_true
  string.contains(note, "privado") |> should.be_true
  let assert [Private("telegram:100", text, True)] = drain(sent)
  string.starts_with(text, "Enviar o formulário em a.com.") |> should.be_true

  // Asking again for the same thing sends nothing new.
  let assert Ok(_) =
    servico.pedir(context, "telegram:100", draft("a.com", Once), in_group: True)
  drain(sent) |> should.equal([])
}

pub fn yes_decides_tells_the_person_and_the_agent_test() {
  let #(now, _) = clock(0)
  let #(context, sent) = context("sim", now)
  let assert Ok(_) =
    servico.pedir(context, "telegram:100", draft("a.com", ForTask), False)
  let _ = drain(sent)

  let assert Some(reply) = servico.answer_text(context, "telegram:100", "sim")
  string.starts_with(reply, "Aprovado") |> should.be_true
  let assert [Injected(message)] = drain(sent)
  message.channel_id |> should.equal("-200")
  message.user_id |> should.equal("100")
  string.starts_with(message.content, "[Aprovação 1] aprovada")
  |> should.be_true
  aprovacoes.allowed(
    context.data_dir,
    "telegram:100",
    1,
    Send,
    "a.com",
    Some(4),
  )
  |> should.equal(Ok(True))
}

pub fn a_voice_no_with_a_number_refuses_test() {
  let #(now, _) = clock(0)
  let #(context, sent) = context("voz", now)
  let assert Ok(_) =
    servico.pedir(context, "telegram:100", draft("a.com", Once), False)
  let assert Ok(_) =
    servico.pedir(context, "telegram:100", draft("b.com", Once), False)
  let _ = drain(sent)

  // Two pending: a bare answer asks which.
  let assert Some(which) = servico.answer_text(context, "telegram:100", "não")
  string.contains(which, "número") |> should.be_true
  drain(sent) |> should.equal([])

  let assert Some(reply) =
    servico.answer_text(
      context,
      "telegram:100",
      "[mensagem de voz de 1 s, transcrita]\nNão, dois.",
    )
  string.starts_with(reply, "Recusado") |> should.be_true
  let assert [Injected(message)] = drain(sent)
  string.starts_with(message.content, "[Aprovação 2] recusada")
  |> should.be_true
}

pub fn a_button_decides_test() {
  let #(now, _) = clock(0)
  let #(context, sent) = context("botao", now)
  let assert Ok(_) =
    servico.pedir(context, "telegram:100", draft("a.com", Once), False)
  let _ = drain(sent)
  let assert Some(reply) =
    servico.answer_button(context, "telegram:100", "aprovacao:1:sim")
  string.starts_with(reply, "Aprovado") |> should.be_true
  // A second press, on the reminder or the first message, says what
  // became of the request.
  let assert Some(again) =
    servico.answer_button(context, "telegram:100", "aprovacao:1:nao")
  string.starts_with(again, "Aprovado") |> should.be_true
  drain(sent) |> list.length |> should.equal(1)
  servico.answer_button(context, "telegram:100", "modelo:x")
  |> should.equal(None)
}

pub fn other_messages_go_to_the_agent_test() {
  let #(now, _) = clock(0)
  let #(context, sent) = context("outras", now)
  // Nothing pending: even "sim" is a message for the agent.
  servico.answer_text(context, "telegram:100", "sim") |> should.equal(None)
  let assert Ok(_) =
    servico.pedir(context, "telegram:100", draft("a.com", Once), False)
  let _ = drain(sent)
  servico.answer_text(context, "telegram:100", "quanto custa isso?")
  |> should.equal(None)
  servico.answer_text(
    context,
    "telegram:100",
    "[mensagem de voz encaminhada, transcrita]\nsim",
  )
  |> should.equal(None)
}

pub fn someone_else_cannot_answer_test() {
  let #(now, _) = clock(0)
  let #(context, sent) = context("outra_pessoa", now)
  let assert Ok(_) =
    servico.pedir(context, "telegram:100", draft("a.com", Once), False)
  let _ = drain(sent)
  servico.answer_text(context, "telegram:200", "sim 1") |> should.equal(None)
  let assert Some(reply) =
    servico.answer_button(context, "telegram:200", "aprovacao:1:sim")
  string.contains(reply, "Não há pedido 1") |> should.be_true
  let assert Ok([_]) = aprovacoes.pending(context.data_dir, "telegram:100")
  drain(sent) |> should.equal([])
}

pub fn the_clock_reminds_once_and_expires_test() {
  let #(now, set) = clock(0)
  let #(context, sent) = context("relogio", now)
  let assert Ok(_) =
    servico.pedir(context, "telegram:100", draft("a.com", Once), False)
  let _ = drain(sent)

  set(2 * hour)
  servico.tick_all(context)
  drain(sent) |> should.equal([])

  set(3 * hour)
  servico.tick_all(context)
  let assert [Private("telegram:100", reminder, True)] = drain(sent)
  string.starts_with(reminder, "Lembrete") |> should.be_true
  servico.tick_all(context)
  drain(sent) |> should.equal([])

  set(24 * hour)
  servico.tick_all(context)
  let messages = drain(sent)
  let assert [Private("telegram:100", told, False), Injected(message)] =
    messages
  string.contains(told, "expirou") |> should.be_true
  string.starts_with(message.content, "[Aprovação 1] expirou")
  |> should.be_true
  list.length(messages) |> should.equal(2)
}

pub fn a_task_that_ends_cancels_and_tells_test() {
  let #(now, _) = clock(0)
  let #(context, sent) = context("tarefa", now)
  let assert Ok(_) =
    servico.pedir(context, "telegram:100", draft("a.com", Once), False)
  let _ = drain(sent)
  servico.task_ended(context, "telegram:100", 4)
  let assert [Private("telegram:100", text, False)] = drain(sent)
  string.contains(text, "cancelado") |> should.be_true
  aprovacoes.pending(context.data_dir, "telegram:100") |> should.equal(Ok([]))
}

@external(erlang, "supernova_global_ffi", "global_put")
fn put(key: String, value: Int) -> Nil

@external(erlang, "supernova_global_ffi", "global_get")
fn get(key: String) -> Int

pub fn the_private_chat_has_buttons_where_the_channel_does_test() {
  let buttons = Some(port.ChannelInteractiveReply([]))
  let assert Ok(#("telegram", on_telegram)) =
    servico.private_reply("telegram:100", "Pedido", buttons)
  on_telegram.channel_id |> should.equal("100")
  on_telegram.interactive |> should.equal(buttons)
  let assert Ok(#("whatsapp", on_whatsapp)) =
    servico.private_reply("whatsapp:5511999999999", "Pedido", buttons)
  on_whatsapp.interactive |> should.equal(None)
  on_whatsapp.content |> should.equal("Pedido")
  servico.private_reply("ninguem", "Pedido", buttons) |> should.be_error
}
