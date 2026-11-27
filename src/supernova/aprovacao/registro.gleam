//// What the person hears about effects outside the machine comes from the
//// gate's register, not from the model (PRD-K, K-I9). The computer tool
//// writes a `[registro]` line for each send, login or file change the gate
//// let through; at the end of the turn the code adds them to the reply.
//// If the reply says something was sent and the register has nothing, the
//// person hears that nothing was sent.
////
//// (Origin: in Andon Labs' radio experiment, a model announced sponsors
//// that did not exist.)

import gleam/list
import gleam/string

pub const line = "[registro] "

/// The effects registered in a turn's tool results.
pub fn effects(results: List(String)) -> List(String) {
  results
  |> list.flat_map(fn(text) { string.split(text, "\n") })
  |> list.filter_map(fn(row) {
    case string.split_once(row, line) {
      Ok(#("", effect)) -> Ok(string.trim(effect))
      _ -> Error(Nil)
    }
  })
  |> list.unique
}

/// Words with which a reply says something went out. A heuristic: it only
/// adds a sentence of the code, never removes the agent's.
const claims = [
  "enviei", "mandei", "foi enviado", "foi enviada", "foram enviados", "submeti",
  "paguei", "foi pago", "comprei", "publiquei", "postei", "confirmei o",
  "agendei", "marquei a", "marquei o", "fiz a inscrição", "fiz o cadastro",
  "cadastrei",
]

pub fn claims_effect(reply: String) -> Bool {
  let text = string.lowercase(reply)
  list.any(claims, fn(word) { string.contains(text, word) })
}

/// The reply as the person hears it: with what the register says.
pub fn note(reply: String, effects: List(String), used_agenda: Bool) -> String {
  case effects {
    [_, ..] ->
      reply <> "\n\nRegistro do portão: " <> string.join(effects, "; ") <> "."
    [] ->
      case claims_effect(reply) && !used_agenda {
        True ->
          reply
          <> "\n\nRegistro do portão: nada foi enviado para fora do computador nesta conversa."
        False -> reply
      }
  }
}
