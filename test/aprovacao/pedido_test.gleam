import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/aprovacao/pedido.{Always, Answer, Decide, Explain, No, Yes}
import supernova/channel/port
import supernova/self/aprovacoes.{
  Approve, ForTask, Once, Pending, Permanent, Refuse, Request, Send,
}

fn request(id: Int, always: Bool) {
  Request(
    id: id,
    kind: Send,
    target: "consultas.saude.gov.br",
    summary: "Enviar o formulário de agendamento em consultas.saude.gov.br.",
    explanation: "É para marcar a consulta de terça.",
    task: Some(4),
    approve: ForTask,
    always: always,
    origin: aprovacoes.Chat("telegram", "-200", "100"),
    status: Pending,
    created_at: 0,
    reminded: False,
    decided_at: None,
  )
}

// ---------------------------------------------------------------- the text

pub fn the_first_sentence_is_the_code_s_test() {
  let text = pedido.message(request(3, True), alone: True)
  text
  |> string.starts_with(
    "Enviar o formulário de agendamento em consultas.saude.gov.br.",
  )
  |> should.be_true
  string.contains(text, "É para marcar a consulta de terça.") |> should.be_true
  // How to answer without buttons, by text or voice.
  string.contains(text, "Responda sim ou não") |> should.be_true
  string.contains(text, "sempre") |> should.be_true
}

pub fn with_others_pending_the_answer_carries_the_number_test() {
  let text = pedido.message(request(3, False), alone: False)
  string.contains(text, "sim 3") |> should.be_true
  string.contains(text, "não 3") |> should.be_true
  // No "always" when the request does not take it (K10).
  string.contains(text, "sempre") |> should.be_false
}

pub fn an_empty_explanation_leaves_no_gap_test() {
  let text =
    pedido.message(Request(..request(1, False), explanation: ""), alone: True)
  string.contains(text, "\n\n\n") |> should.be_false
}

pub fn buttons_approve_refuse_and_always_when_offered_test() {
  let port.ChannelInteractiveReply(blocks) = pedido.buttons(request(3, True))
  let assert [port.InteractionButtons(buttons)] = blocks
  list.map(buttons, port.button_label)
  |> should.equal(["Aprovar", "Recusar", "Sempre"])
  let port.ChannelInteractiveReply(blocks) = pedido.buttons(request(3, False))
  let assert [port.InteractionButtons(buttons)] = blocks
  list.map(buttons, port.button_label) |> should.equal(["Aprovar", "Recusar"])
}

pub fn a_button_is_read_back_test() {
  let port.ChannelInteractiveReply(blocks) = pedido.buttons(request(3, True))
  let assert [port.InteractionButtons(buttons)] = blocks
  let actions =
    list.map(buttons, fn(b) {
      let port.ChannelButton(action_id: action, ..) = b
      pedido.parse_action(action)
    })
  actions
  |> should.equal([
    Some(Answer(Yes, Some(3))),
    Some(Answer(No, Some(3))),
    Some(Answer(Always, Some(3))),
  ])
  pedido.parse_action("modelo:openai") |> should.equal(None)
  pedido.parse_action("aprovacao:x:sim") |> should.equal(None)
}

// ---------------------------------------------------------- the answer

pub fn plain_answers_are_recognised_test() {
  pedido.parse("sim") |> should.equal(Some(Answer(Yes, None)))
  pedido.parse("Sim.") |> should.equal(Some(Answer(Yes, None)))
  pedido.parse("  SIM 2 ") |> should.equal(Some(Answer(Yes, Some(2))))
  pedido.parse("sim, 2") |> should.equal(Some(Answer(Yes, Some(2))))
  pedido.parse("sim #2") |> should.equal(Some(Answer(Yes, Some(2))))
  pedido.parse("aprovo") |> should.equal(Some(Answer(Yes, None)))
  // The words of PRD-K, section 3.3.
  pedido.parse("s") |> should.equal(Some(Answer(Yes, None)))
  pedido.parse("ok") |> should.equal(Some(Answer(Yes, None)))
  pedido.parse("Isso.") |> should.equal(Some(Answer(Yes, None)))
  pedido.parse("n") |> should.equal(Some(Answer(No, None)))
  pedido.parse("cancela") |> should.equal(Some(Answer(No, None)))
  pedido.parse("sim sempre") |> should.equal(Some(Answer(Always, None)))
  pedido.parse("sim sempre 2") |> should.equal(Some(Answer(Always, Some(2))))
  pedido.parse("autorizo") |> should.equal(None)
  pedido.parse("pode") |> should.equal(Some(Answer(Yes, None)))
  pedido.parse("não") |> should.equal(Some(Answer(No, None)))
  pedido.parse("Nao 4") |> should.equal(Some(Answer(No, Some(4))))
  pedido.parse("recuso") |> should.equal(Some(Answer(No, None)))
  pedido.parse("sempre") |> should.equal(Some(Answer(Always, None)))
  pedido.parse("Sempre 7!") |> should.equal(Some(Answer(Always, Some(7))))
}

pub fn anything_longer_goes_to_the_agent_test() {
  pedido.parse("sim, mas antes me diga o preço") |> should.equal(None)
  pedido.parse("não sei") |> should.equal(None)
  pedido.parse("simples") |> should.equal(None)
  pedido.parse("") |> should.equal(None)
  pedido.parse("2") |> should.equal(None)
}

pub fn a_voice_note_counts_test() {
  pedido.parse("[mensagem de voz de 2 s, transcrita]\nSim.")
  |> should.equal(Some(Answer(Yes, None)))
  // Spoken numbers come back as words.
  pedido.parse("[mensagem de voz, transcrita]\nNão, dois.")
  |> should.equal(Some(Answer(No, Some(2))))
  pedido.parse("sim, número três") |> should.equal(Some(Answer(Yes, Some(3))))
  pedido.parse("sim pedido 12") |> should.equal(Some(Answer(Yes, Some(12))))
  pedido.parse("[mensagem de voz, transcrita]\nnão 2")
  |> should.equal(Some(Answer(No, Some(2))))
}

pub fn a_forwarded_voice_note_never_counts_test() {
  // Someone else's voice saying "sim" is not the person deciding (K-I2).
  pedido.parse("[mensagem de voz encaminhada de 2 s, transcrita]\nSim.")
  |> should.equal(None)
  pedido.parse("[áudio encaminhado, transcrito]\nsim") |> should.equal(None)
}

// ---------------------------------------------------- which request

pub fn one_pending_takes_a_bare_answer_test() {
  pedido.resolve(Answer(Yes, None), [request(3, True)])
  |> should.equal(Decide(3, Approve(ForTask)))
  pedido.resolve(Answer(No, None), [request(3, True)])
  |> should.equal(Decide(3, Refuse))
  pedido.resolve(Answer(Always, None), [request(3, True)])
  |> should.equal(Decide(3, Approve(Permanent)))
}

pub fn yes_grants_what_the_request_offers_test() {
  pedido.resolve(Answer(Yes, Some(3)), [
    Request(..request(3, False), approve: Once),
  ])
  |> should.equal(Decide(3, Approve(Once)))
}

pub fn several_pending_need_the_number_test() {
  let assert Explain(text) =
    pedido.resolve(Answer(Yes, None), [request(3, True), request(4, True)])
  string.contains(text, "sim 3") |> should.be_true
  string.contains(text, "4") |> should.be_true
  pedido.resolve(Answer(No, Some(4)), [request(3, True), request(4, True)])
  |> should.equal(Decide(4, Refuse))
}

pub fn a_number_that_is_not_pending_is_told_test() {
  let assert Explain(text) =
    pedido.resolve(Answer(Yes, Some(9)), [request(3, True)])
  string.contains(text, "9") |> should.be_true
}

pub fn always_where_it_is_not_offered_is_told_test() {
  let assert Explain(text) =
    pedido.resolve(Answer(Always, None), [request(3, False)])
  string.contains(text, "sim ou não") |> should.be_true
}

// ------------------------------------------------------------ notes

pub fn the_agent_hears_the_outcome_test() {
  let approved =
    Request(..request(3, True), status: aprovacoes.Approved)
    |> pedido.outcome_note
  string.starts_with(approved, "[Aprovação 3] aprovada") |> should.be_true
  let refused =
    Request(..request(3, True), status: aprovacoes.Refused)
    |> pedido.outcome_note
  string.starts_with(refused, "[Aprovação 3] recusada") |> should.be_true
  let expired =
    Request(..request(3, True), status: aprovacoes.Expired)
    |> pedido.outcome_note
  string.starts_with(expired, "[Aprovação 3] expirou") |> should.be_true
}

pub fn the_tool_tells_the_agent_to_wait_test() {
  pedido.asked_note(request(3, True), in_group: False)
  |> string.contains("Pedi aprovação (3)")
  |> should.be_true
  pedido.asked_note(request(3, True), in_group: True)
  |> string.contains("privado")
  |> should.be_true
}
