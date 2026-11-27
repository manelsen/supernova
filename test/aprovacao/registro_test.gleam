import gleeunit/should
import supernova/aprovacao/registro

pub fn the_register_tells_what_went_out_test() {
  let effects =
    registro.effects([
      "Saída do seu computador\n{...}\n[registro] formulário enviado em saude.gov.br",
      "nada aqui",
      "[registro] entrou na conta em gov.br",
    ])
  effects
  |> should.equal([
    "formulário enviado em saude.gov.br",
    "entrou na conta em gov.br",
  ])
  registro.note("Pronto, marquei.", effects, False)
  |> should.equal(
    "Pronto, marquei.\n\nRegistro do portão: formulário enviado em saude.gov.br; entrou na conta em gov.br.",
  )
}

pub fn a_claim_without_a_register_is_corrected_test() {
  registro.note("Enviei o formulário para você!", [], False)
  |> should.equal(
    "Enviei o formulário para você!\n\nRegistro do portão: nada foi enviado para fora do computador nesta conversa.",
  )
  // An agenda entry is not an effect outside: the agenda said so itself.
  registro.note("Agendei para amanhã.", [], True)
  |> should.equal("Agendei para amanhã.")
  registro.note("Oi! Tudo bem?", [], False) |> should.equal("Oi! Tudo bem?")
}
