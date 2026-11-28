//// PRD-Q: the clock, the decision's answer and the tool.

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/proativa/decisor
import supernova/proativa/estado
import supernova/proativa/relogio
import supernova/tools/proativa as proativa_tool

const offset = -180

/// 27/11/2026, 21:00 in São Paulo: every slot of the day is open by now.
const noite = 1_795_824_000_000

/// 27/11/2026, 23:00 in São Paulo: silence.
const tarde_demais = 1_795_831_200_000

const ana = "whatsapp:5531999"

fn dir(nome: String) -> String {
  let d = "build/proativa_relogio_test_" <> nome
  let _ = delete_dir(d)
  // Born: the agent has a core in prose.
  let assert Ok(_) = ensure_dir(d <> "/agents/whatsapp_5531999/self")
  let assert Ok(_) =
    write_file(d <> "/agents/whatsapp_5531999/self/core.md", "Sou a Lua.")
  d
}

fn sim(_principal, _estado) {
  Some(decisor.Assunto(tema: "motores de jogos", ideia: "a luz 2D na Godot"))
}

pub fn a_yes_becomes_one_message_in_the_private_chat_test() {
  let d = dir("sim")
  let sent = process.new_subject()
  relogio.sweep(d, offset, noite, sim, fn(m) { process.send(sent, m) })
  |> should.equal(1)
  let assert Ok(message) = process.receive(sent, 100)
  relogio.e_proativa(message.id) |> should.be_true
  message.channel |> should.equal("whatsapp")
  message.channel_id |> should.equal("5531999@s.whatsapp.net")
  string.contains(message.content, "motores de jogos") |> should.be_true
  string.contains(message.content, "Não peça aprovação") |> should.be_true
  // Q-I2: the next pass, with no answer yet, sends nothing.
  relogio.sweep(d, offset, noite + 600_000, sim, fn(m) { process.send(sent, m) })
  |> should.equal(0)
  process.receive(sent, 50) |> should.be_error
  let _ = delete_dir(d)
  Nil
}

pub fn a_no_uses_the_slot_and_sends_nothing_test() {
  let d = dir("nao")
  let sent = process.new_subject()
  relogio.sweep(d, offset, noite, fn(_, _) { None }, fn(m) {
    process.send(sent, m)
  })
  |> should.equal(0)
  process.receive(sent, 50) |> should.be_error
  estado.carregar(d, ana).tentativas |> should.equal(1)
  let _ = delete_dir(d)
  Nil
}

// Q-I1: at night nothing is even decided.
pub fn at_night_the_decision_is_not_even_asked_test() {
  let d = dir("noite")
  relogio.sweep(
    d,
    offset,
    tarde_demais,
    fn(_, _) { panic as "no decision in the silence" },
    fn(_) { panic as "no message in the silence" },
  )
  |> should.equal(0)
  let _ = delete_dir(d)
  Nil
}

pub fn an_unborn_agent_is_left_alone_test() {
  let d = "build/proativa_relogio_test_vazio"
  let _ = delete_dir(d)
  let assert Ok(_) = ensure_dir(d <> "/agents/whatsapp_5531888/self")
  relogio.pessoas(d) |> should.equal([])
  let _ = delete_dir(d)
  Nil
}

// Q-I3: talk and look things up, nothing that acts or asks.
pub fn a_proactive_turn_only_talks_and_looks_up_test() {
  relogio.ferramenta_permitida("web_fetch", "{}") |> should.be_true
  relogio.ferramenta_permitida("lembrar", "{}") |> should.be_true
  relogio.ferramenta_permitida("computador", "{}") |> should.be_false
  relogio.ferramenta_permitida("agenda", "{}") |> should.be_false
  relogio.ferramenta_permitida("file_system", "{}") |> should.be_false
  relogio.ferramenta_permitida("tarefa", "{}") |> should.be_false
  relogio.ferramenta_permitida(
    "sonda",
    "{\"tipo\":\"web\",\"teto_usd\":\"0.50\"}",
  )
  |> should.be_true
  relogio.ferramenta_permitida("sonda", "{\"tipo\":\"web\"}")
  |> should.be_true
  // Above US$ 0.50 a probe asks the person first: not here.
  relogio.ferramenta_permitida(
    "sonda",
    "{\"tipo\":\"web\",\"teto_usd\":\"0,51\"}",
  )
  |> should.be_false
  relogio.ferramenta_permitida("sonda", "{\"tipo\":\"codigo\"}")
  |> should.be_false
}

pub fn the_decision_is_read_or_it_is_a_no_test() {
  decisor.ler(
    "```json\n{\"falar\": true, \"tema\": \"Godot\", \"ideia\": \"luz 2D\"}\n```",
  )
  |> should.equal(Some(decisor.Assunto("Godot", "luz 2D")))
  decisor.ler("{\"falar\": false, \"tema\": \"Godot\"}") |> should.equal(None)
  decisor.ler("{\"falar\": true, \"tema\": \"\"}") |> should.equal(None)
  decisor.ler("acho que sim") |> should.equal(None)
}

pub fn the_decision_sees_the_subject_rule_test() {
  let contexto =
    decisor.Contexto(
      nucleo: "",
      trocas: [#("oi", "olá")],
      agenda: [],
      agora: "sexta, 10h",
      regra: estado.regra_dos_assuntos(estado.SoMeus),
    )
  let assert [system, user] = decisor.pergunta(contexto)
  string.contains(system.content, "Nunca toque") |> should.be_true
  string.contains(user.content, "Pessoa: oi") |> should.be_true
}

pub fn the_person_sets_it_through_the_tool_test() {
  let d = dir("ferramenta")
  let assert Ok(resumo) =
    proativa_tool.execute_for(d, ana, "{\"acao\":\"desligar\"}")
  string.contains(resumo, "desligado") |> should.be_true
  estado.carregar(d, ana).ligada |> should.be_false
  let assert Ok(_) =
    proativa_tool.execute_for(
      d,
      ana,
      "{\"acao\":\"silencio\",\"de\":21,\"ate\":9}",
    )
  estado.carregar(d, ana).silencio_de |> should.equal(21)
  proativa_tool.execute_for(
    d,
    ana,
    "{\"acao\":\"assuntos\",\"assuntos\":\"x\"}",
  )
  |> should.be_error
  proativa_tool.execute_for(d, ana, "{\"acao\":\"explodir\"}")
  |> should.be_error
  let _ = delete_dir(d)
  Nil
}

@external(erlang, "file", "del_dir_r")
fn delete_dir(path: String) -> a

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)
