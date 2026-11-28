//// PRD-Q: the rules of when the agent may start a conversation.

import gleam/string
import gleeunit/should
import supernova/proativa/estado.{Aberta, Estado, Fechada}

/// São Paulo.
const offset = -180

/// 27/11/2026 00:00 in São Paulo.
const meia_noite = 1_795_748_400_000

fn em(hora: Int, minuto: Int) -> Int {
  meia_noite + { hora * 60 + minuto } * 60_000
}

fn hoje() -> estado.Estado {
  estado.para_o_dia(estado.inicial(), "2026-11-27")
}

pub fn the_local_day_and_minute_test() {
  estado.dia_local(em(0, 0), offset) |> should.equal("2026-11-27")
  estado.dia_local(em(23, 59), offset) |> should.equal("2026-11-27")
  estado.dia_local(em(24, 0), offset) |> should.equal("2026-11-28")
  estado.minuto_local(em(10, 30), offset) |> should.equal(630)
}

pub fn silence_crosses_midnight_test() {
  estado.em_silencio(22 * 60, 22, 8) |> should.be_true
  estado.em_silencio(3 * 60, 22, 8) |> should.be_true
  estado.em_silencio(8 * 60, 22, 8) |> should.be_false
  estado.em_silencio(13 * 60, 22, 8) |> should.be_false
  estado.em_silencio(13 * 60, 12, 14) |> should.be_true
}

// Q-I1: nothing in the person's silence, nor turned off, nor above the
// ceiling.
pub fn never_at_night_off_or_above_the_ceiling_test() {
  estado.janela(hoje(), em(23, 0), offset, "ana")
  |> should.equal(Fechada("silêncio"))
  estado.janela(hoje(), em(7, 59), offset, "ana")
  |> should.equal(Fechada("silêncio"))
  estado.janela(estado.desligar(hoje()), em(21, 0), offset, "ana")
  |> should.equal(Fechada("desligada"))
  estado.janela(Estado(..hoje(), tentativas: 3), em(21, 0), offset, "ana")
  |> should.equal(Fechada("teto do dia"))
}

// Q-I2: never two in a row without an answer.
pub fn never_two_without_an_answer_test() {
  let falou = estado.falou(hoje(), em(10, 0))
  estado.janela(falou, em(21, 0), offset, "ana")
  |> should.equal(Fechada("aguardando resposta"))
  let respondeu = estado.pessoa_falou(falou)
  estado.janela(respondeu, em(21, 0), offset, "ana") |> should.equal(Aberta)
}

pub fn a_slot_opens_at_its_own_moment_test() {
  let e = hoje()
  let hora = estado.hora_do_slot(e, 0, "ana")
  // The first of three slots falls in the first third of the waking day.
  { hora >= 8 * 60 && hora < 8 * 60 + 280 } |> should.be_true
  let antes = meia_noite + { hora - 1 } * 60_000
  let na_hora = meia_noite + hora * 60_000
  case hora > 8 * 60 {
    True ->
      estado.janela(e, antes, offset, "ana")
      |> should.equal(Fechada("ainda não"))
    False -> Nil
  }
  estado.janela(e, na_hora, offset, "ana") |> should.equal(Aberta)
  // Another person's slot opens at another moment, the same every day.
  estado.hora_do_slot(e, 0, "ana") |> should.equal(hora)
}

pub fn a_new_day_frees_the_slots_test() {
  let ontem = Estado(..estado.inicial(), dia: "2026-11-26", tentativas: 3)
  estado.janela(ontem, em(21, 0), offset, "ana") |> should.equal(Aberta)
  estado.calou(hoje()).tentativas |> should.equal(1)
}

// D3: three answers in a row raise the ceiling, up to six.
pub fn answers_raise_the_ceiling_test() {
  let responde = fn(e) { estado.pessoa_falou(estado.falou(e, em(10, 0))) }
  let e = hoje() |> responde |> responde
  e.teto |> should.equal(3)
  let e = responde(e)
  e.teto |> should.equal(4)
  let e = e |> responde |> responde |> responde |> responde |> responde
  let e = e |> responde |> responde |> responde |> responde |> responde
  e.teto |> should.equal(6)
  // A message of the person with nothing waiting changes nothing.
  estado.pessoa_falou(hoje()) |> should.equal(hoje())
}

// D3: one ignored for a day lowers the ceiling, once, down to one.
pub fn an_ignored_message_lowers_the_ceiling_once_test() {
  let falou = estado.falou(hoje(), em(10, 0))
  estado.ver_ignorada(falou, em(20, 0)).teto |> should.equal(3)
  let dia_depois = em(10, 0) + estado.ignorada_apos_ms
  let baixou = estado.ver_ignorada(falou, dia_depois)
  baixou.teto |> should.equal(2)
  estado.ver_ignorada(baixou, dia_depois + 1000).teto |> should.equal(2)
  let minimo = Estado(..falou, teto: 1)
  estado.ver_ignorada(minimo, dia_depois).teto |> should.equal(1)
}

pub fn what_the_person_sets_test() {
  estado.mais(Estado(..hoje(), teto: 6)).teto |> should.equal(6)
  estado.menos(Estado(..hoje(), teto: 1)).teto |> should.equal(1)
  let assert Ok(e) = estado.silencio(hoje(), 21, 9)
  #(e.silencio_de, e.silencio_ate) |> should.equal(#(21, 9))
  estado.silencio(hoje(), 25, 9) |> should.be_error
  estado.assuntos_de("só os meus") |> should.equal(Ok(estado.SoMeus))
  estado.assuntos_de("livres") |> should.equal(Ok(estado.Livres))
  estado.assuntos_de("tudo") |> should.equal(Error(Nil))
}

// Q-I4 (the code's part): with sensitive subjects closed, the agent is told
// never to bring them up, not even lightly.
pub fn the_subject_rule_follows_the_setting_test() {
  estado.regra_dos_assuntos(estado.SoMeus)
  |> string.contains("Nunca toque")
  |> should.be_true
  estado.regra_dos_assuntos(estado.Leve)
  |> string.contains("não volte ao detalhe")
  |> should.be_true
}

pub fn it_is_kept_on_disk_test() {
  let dir = "build/proativa_estado_test"
  let _ = delete_dir(dir)
  estado.carregar(dir, "whatsapp:5531").ligada |> should.be_true
  let assert Ok(_) =
    estado.mudar(dir, "whatsapp:5531", fn(e) { Ok(estado.desligar(e)) })
  estado.carregar(dir, "whatsapp:5531").ligada |> should.be_false
  let _ = delete_dir(dir)
  Nil
}

@external(erlang, "file", "del_dir_r")
fn delete_dir(path: String) -> a

// The day's slots are not all spent in the morning: after speaking, three
// hours pass before the next, even when the person answers at once.
pub fn three_hours_between_two_test() {
  let respondeu = estado.pessoa_falou(estado.falou(hoje(), em(10, 0)))
  estado.janela(respondeu, em(12, 59), offset, "ana")
  |> should.equal(Fechada("intervalo"))
  estado.janela(respondeu, em(21, 0), offset, "ana") |> should.equal(Aberta)
}

// The interval is the person's, 1 to 12 hours.
pub fn the_interval_is_per_person_test() {
  let assert Ok(curto) = estado.intervalo(hoje(), 1)
  let respondeu = estado.pessoa_falou(estado.falou(curto, em(10, 0)))
  estado.janela(respondeu, em(10, 30), offset, "ana")
  |> should.equal(Fechada("intervalo"))
  { estado.janela(respondeu, em(11, 0), offset, "ana") != Fechada("intervalo") }
  |> should.be_true
  estado.intervalo(hoje(), 0) |> should.be_error
  estado.intervalo(hoje(), 13) |> should.be_error
}
