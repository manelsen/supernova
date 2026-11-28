//// PRD-Q, D4: when a slot opens, a cheap call decides whether the agent
//// should start a conversation now, and about what. The code opened the
//// window; this only chooses inside it, and may say no.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/agenda/schedule
import supernova/agenda/store as agenda_store
import supernova/llm/client
import supernova/llm/provider
import supernova/proativa/estado.{type Estado}
import supernova/self/core
import supernova/self/journal

/// What to talk about, when the answer is yes.
pub type Assunto {
  Assunto(tema: String, ideia: String)
}

/// What the decision sees about the person.
pub type Contexto {
  Contexto(
    nucleo: String,
    trocas: List(#(String, String)),
    agenda: List(String),
    agora: String,
    regra: String,
  )
}

/// The context from disk: the agent's core in prose, the last exchanges,
/// the agenda of the next day and a half.
pub fn contexto(
  data_dir: String,
  principal: String,
  estado: Estado,
  now_ms: Int,
  offset: Int,
) -> Contexto {
  let nucleo =
    read_file(core.prose_path(data_dir, principal))
    |> result.unwrap("")
    |> string.slice(0, 1500)
  let trocas =
    journal.load(data_dir, principal)
    |> list.reverse
    |> list.take(6)
    |> list.reverse
    |> list.map(fn(entry) {
      #(string.slice(entry.user, 0, 300), string.slice(entry.agent, 0, 300))
    })
  let agenda =
    agenda_store.list(data_dir, principal)
    |> list.filter(fn(entry) {
      entry.next_run_at > now_ms && entry.next_run_at - now_ms < 129_600_000
    })
    |> list.map(fn(entry) {
      schedule.format_local(entry.next_run_at, offset) <> ": " <> entry.request
    })
  Contexto(
    nucleo: nucleo,
    trocas: trocas,
    agenda: agenda,
    agora: schedule.describe_now(now_ms, offset),
    regra: estado.regra_dos_assuntos(estado.assuntos),
  )
}

/// The instruction for the decision.
pub fn pergunta(contexto: Contexto) -> List(provider.ChatMessage) {
  let trocas = case contexto.trocas {
    [] -> "(nenhuma conversa ainda)"
    trocas ->
      trocas
      |> list.map(fn(t) { "Pessoa: " <> t.0 <> "\nAgente: " <> t.1 })
      |> string.join("\n---\n")
  }
  let agenda = case contexto.agenda {
    [] -> "(nada)"
    itens -> string.join(itens, "\n")
  }
  [
    provider.system_message(
      "Você decide se uma agente companheira deve puxar assunto agora com a pessoa dela, por conta própria. "
      <> "Muitas dessas pessoas são cegas ou tetraplégicas e passam boa parte do dia sozinhas: uma mensagem boa, na hora certa, faz companhia. Uma ruim incomoda. "
      <> "Fale só se houver algo que valha mesmo: um tema de que a pessoa gosta ou que estava estudando, sobre o qual dá para pesquisar algo novo e interessante; um compromisso próximo; uma continuação natural de uma conversa. "
      <> "Nunca peça nada que exija aprovação, nunca proponha agir no computador. "
      <> contexto.regra
      <> " Responda só com JSON: {\"falar\": true ou false, \"tema\": \"...\", \"ideia\": \"o que pesquisar ou dizer, em uma frase\"}.",
    ),
    provider.user_message(
      "Agora: "
      <> contexto.agora
      <> "\n\nQuem a agente é e o que sabe da pessoa:\n"
      <> case contexto.nucleo {
        "" -> "(ainda pouco)"
        nucleo -> nucleo
      }
      <> "\n\nÚltimas trocas:\n"
      <> trocas
      <> "\n\nAgenda das próximas 36 horas:\n"
      <> agenda,
    ),
  ]
}

/// The decision's answer: Some(subject) to speak, None to stay quiet. A
/// reply that is not the expected JSON is a no.
pub fn ler(resposta: String) -> Option(Assunto) {
  let texto = case string.split_once(resposta, "{") {
    Ok(#(_, depois)) ->
      case string.split_once(string.reverse(depois), "}") {
        Ok(#(_, antes)) -> "{" <> string.reverse(antes) <> "}"
        Error(Nil) -> resposta
      }
    Error(Nil) -> resposta
  }
  let decoder = {
    use falar <- decode.field("falar", decode.bool)
    use tema <- decode.optional_field("tema", "", decode.string)
    use ideia <- decode.optional_field("ideia", "", decode.string)
    decode.success(#(falar, tema, ideia))
  }
  case json.parse(texto, decoder) {
    Ok(#(True, tema, ideia)) ->
      case string.trim(tema) {
        "" -> None
        tema -> Some(Assunto(tema: tema, ideia: string.trim(ideia)))
      }
    _ -> None
  }
}

/// Ask the model. An error is a no: staying quiet is always safe.
pub fn decidir(
  config: provider.ProviderConfig,
  contexto: Contexto,
) -> Option(Assunto) {
  case client.chat(pergunta(contexto), config, []) {
    Ok(resposta) -> ler(resposta.content)
    Error(_) -> None
  }
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)
