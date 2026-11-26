import gleam/option.{Some}
import gleam/string
import gleeunit/should
import supernova/aprovacao/senha
import supernova/self/cofre
import test_workspace

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

pub fn kept_sealed_opened_with_the_key_only_test() {
  let dir = test_workspace.create_temp_dir("cofre")
  let assert Ok(Nil) =
    cofre.guardar(dir, "sim:ana", "chave", "gov.br", "123", "s3nh@ com espaço")
  let assert Ok(text) = read_file(cofre.path(dir, "sim:ana"))
  string.contains(text, "s3nh@") |> should.be_false
  cofre.credencial(dir, "sim:ana", "chave", "gov.br")
  |> should.equal(Ok(#("123", "s3nh@ com espaço")))
  cofre.credencial(dir, "sim:ana", "outra chave", "gov.br") |> should.be_error
  cofre.credencial(dir, "sim:bia", "chave", "gov.br") |> should.be_error
  cofre.sites(dir, "sim:ana") |> should.equal(Ok([#("gov.br", "123")]))
  // Replaced, then deleted.
  let assert Ok(Nil) =
    cofre.guardar(dir, "sim:ana", "chave", "gov.br", "456", "x")
  cofre.sites(dir, "sim:ana") |> should.equal(Ok([#("gov.br", "456")]))
  cofre.apagar(dir, "sim:ana", "gov.br") |> should.equal(Ok(True))
  cofre.apagar(dir, "sim:ana", "gov.br") |> should.equal(Ok(False))
  cofre.sites(dir, "sim:ana") |> should.equal(Ok([]))
}

pub fn the_command_test() {
  senha.parse("/senha") |> should.equal(Some(senha.Listar))
  senha.parse("/senha https://Gov.br/login 123 minha senha")
  |> should.equal(Some(senha.Guardar("gov.br", "123", "minha senha")))
  senha.parse("/senha apagar gov.br")
  |> should.equal(Some(senha.Apagar("gov.br")))
  senha.parse("/senha gov.br 123") |> should.equal(Some(senha.Uso))
  senha.parse("senha gov.br") |> should.be_none
  senha.redact("/senha gov.br 123 minha senha")
  |> should.equal("/senha gov.br 123 [senha omitida]")
  senha.redact("oi") |> should.equal("oi")
  senha.spoken("[mensagem de voz, transcrita]\nBarra senha gov.br 123 abc")
  |> should.be_true
  senha.spoken("[mensagem de voz, transcrita]\nqual é a senha do wifi?")
  |> should.be_false
}
