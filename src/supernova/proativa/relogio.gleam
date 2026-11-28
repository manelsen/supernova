//// PRD-Q, Q-01 and Q-04: the clock that lets the agent start a
//// conversation. Every five minutes, for each person: the rules open a
//// window (estado), a cheap call decides whether to speak and about what
//// (decisor), and a yes becomes a message in the person's private chat,
//// handed to the same router as the agenda's, so access, budgets, history
//// and delivery apply unchanged.

import exception
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/catalog
import supernova/channel/port
import supernova/core/agent_identity
import supernova/metrics/record
import supernova/proativa/decisor.{type Assunto}
import supernova/proativa/estado.{type Estado}
import supernova/self/core

pub const interval_ms = 300_000

/// The prefix of a proactive message's id: the router knows it was the
/// agent's own idea (no "person active", fewer tools).
pub const prefixo = "proativa:"

pub fn declare_metrics() -> Nil {
  list.each(["falou", "calou", "fechada"], fn(outcome) {
    record.declare("proativa_total", [#("outcome", outcome)])
  })
}

/// The tools a conversation the agent started may use: talk and look things
/// up (Q-I3). No computer, no agenda, no files, nothing that asks for an
/// approval.
pub const ferramentas = [
  "web_fetch", "buscar_conversa", "lembrar", "sonda", "agenda",
]

/// A call allowed in such a turn: the agenda only to read it (what the
/// decision saw, the turn sees too); a web probe only, up to US$ 0.50,
/// which never asks the person (above that, a probe asks first).
pub fn ferramenta_permitida(name: String, arguments: String) -> Bool {
  case name {
    "agenda" -> {
      let decoder = {
        use action <- decode.field("action", decode.string)
        decode.success(action)
      }
      json.parse(arguments, decoder) == Ok("list")
    }
    "sonda" -> {
      let decoder = {
        use tipo <- decode.optional_field("tipo", "", decode.string)
        use teto <- decode.optional_field("teto_usd", "0.20", decode.string)
        decode.success(#(tipo, teto))
      }
      case json.parse(arguments, decoder) {
        Ok(#("web", teto)) ->
          case float.parse(string.replace(string.trim(teto), ",", ".")) {
            Ok(valor) -> valor <=. 0.5
            Error(Nil) ->
              case int.parse(string.trim(teto)) {
                Ok(valor) -> valor == 0
                Error(Nil) -> False
              }
          }
        _ -> False
      }
    }
    _ -> list.contains(ferramentas, name)
  }
}

pub fn e_proativa(message_id: String) -> Bool {
  string.starts_with(message_id, prefixo)
}

/// The message the agent receives when it decided to speak.
pub fn mensagem(
  principal: String,
  assunto: Assunto,
  estado: Estado,
  now_ms: Int,
) -> port.ChannelMessage {
  let channel = case string.split(principal, ":") {
    [channel, ..] -> channel
    [] -> principal
  }
  let user_id = agent_identity.user_id_from_principal(principal)
  port.ChannelMessage(
    id: prefixo <> int.to_string(now_ms),
    channel: channel,
    channel_id: catalog.get(channel).private_chat_for(user_id),
    user_id: user_id,
    username: "",
    content: texto(assunto, estado),
    is_bot: False,
    reply_to_id: None,
  )
}

pub fn texto(assunto: Assunto, estado: Estado) -> String {
  "[Proativa] Sua pessoa não escreveu agora: é você quem vai puxar assunto, por iniciativa sua. Tema: "
  <> assunto.tema
  <> case assunto.ideia {
    "" -> "."
    ideia -> ". Ideia: " <> ideia
  }
  <> "\nSe valer, pesquise antes (web_fetch, ou uma sonda de web até US$ 0,50) para trazer algo novo e verdadeiro; a agenda você pode consultar (list). "
  <> "Escreva UMA mensagem curta, que começa pelo essencial e termina numa pergunta fácil de responder por voz. "
  <> "Não peça aprovação, não use o computador, não mande mais de uma mensagem. "
  <> estado.regra_dos_assuntos(estado.assuntos)
}

/// One pass over everyone. Returns how many messages went out.
pub fn sweep(
  data_dir: String,
  offset: Int,
  now: Int,
  decide: fn(String, Estado) -> Option(Assunto),
  deliver: fn(port.ChannelMessage) -> Nil,
) -> Int {
  pessoas(data_dir)
  |> list.fold(0, fn(count, principal) {
    let dia = estado.dia_local(now, offset)
    let atual =
      estado.carregar(data_dir, principal)
      |> estado.para_o_dia(dia)
      |> estado.ver_ignorada(now)
    case estado.janela(atual, now, offset, principal) {
      estado.Fechada(_) -> {
        let _ = estado.salvar(data_dir, principal, atual)
        count
      }
      estado.Aberta ->
        case decide(principal, atual) {
          None -> {
            record.count("proativa_total", [#("outcome", "calou")])
            let _ = estado.salvar(data_dir, principal, estado.calou(atual))
            count
          }
          Some(assunto) -> {
            // Saved before the handoff: a crash in delivery never sends twice.
            let _ = estado.salvar(data_dir, principal, estado.falou(atual, now))
            io.println(
              "proativa: speaking principal="
              <> principal
              <> " tema="
              <> assunto.tema,
            )
            deliver(mensagem(principal, assunto, atual, now))
            record.count("proativa_total", [#("outcome", "falou")])
            count + 1
          }
        }
    }
  })
}

/// People with an agent that was born (it has a core) on a channel with a
/// private chat.
pub fn pessoas(data_dir: String) -> List(String) {
  case list_dir(data_dir <> "/agents") {
    Error(_) -> []
    Ok(names) ->
      names
      |> list.map(agent_identity.decode_principal)
      |> list.filter(fn(principal) {
        string.contains(principal, ":")
        && file_exists(core.prose_path(data_dir, principal)) == Ok(True)
      })
  }
}

/// Start the five-minute clock. A crash in one pass is logged and the
/// clock keeps going.
pub fn start(
  data_dir: String,
  offset: Int,
  clock: fn() -> Int,
  decide: fn(String, Estado) -> Option(Assunto),
  deliver: fn(port.ChannelMessage) -> Nil,
) -> Nil {
  declare_metrics()
  let _ =
    process.spawn_unlinked(fn() {
      loop(data_dir, offset, clock, decide, deliver)
    })
  Nil
}

fn loop(data_dir, offset, clock: fn() -> Int, decide, deliver) -> Nil {
  process.sleep(interval_ms)
  case
    exception.rescue(fn() { sweep(data_dir, offset, clock(), decide, deliver) })
  {
    Ok(_) -> Nil
    Error(error) ->
      io.println_error(
        "error: proativa sweep crashed: " <> string.inspect(error),
      )
  }
  loop(data_dir, offset, clock, decide, deliver)
}

@external(erlang, "supernova_file_system_ffi", "list_dir")
fn list_dir(path: String) -> Result(List(String), String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)
