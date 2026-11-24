//// Did the person correct what the agent said it remembered?
//// (docs/prd/PRD-M-memoria.md, 6.6.)
////
//// After a turn in which `lembrar` ran, the person's next message goes to
//// the Decision API with the agent's previous reply. Only the answer is
//// counted: the rate of corrections is the pilot's alarm that the short
//// list or the tone is wrong. Nothing is kept but a mark per person, in
//// memory, until that next message.

import gleam/dict
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/memory/decision
import supernova/memory/runtime

pub const question =
  "Na mensagem da pessoa, ela está corrigindo ou contestando algo que a agente disse lembrar (dizendo que não foi assim, que foi outra coisa, ou que ela contou sim)?"

pub type Correction {
  Corrected
  NotCorrected
  Unknown(decision.DecisionError)
}

/// `lembrar` ran in this person's turn: check the next message.
pub fn mark(principal: String) -> Nil {
  known_put(key(principal), True)
}

/// Whether the previous turn of this person used `lembrar`; the mark is
/// consumed.
pub fn take_mark(principal: String) -> Bool {
  case known_get(key(principal)) {
    Ok(True) -> {
      known_delete(key(principal))
      True
    }
    _ -> False
  }
}

/// After a turn with `lembrar`, whether `message` corrects `previous_reply`.
/// None when the previous turn did not use `lembrar`, or when there is no
/// reply to compare with.
pub fn check(
  settings: runtime.Settings,
  principal: String,
  previous_reply: Option(String),
  message: String,
) -> Option(Correction) {
  case take_mark(principal), previous_reply {
    True, Some(reply) -> Some(ask(settings, principal, reply, message))
    _, _ -> None
  }
}

pub fn ask(
  settings: runtime.Settings,
  principal: String,
  reply: String,
  message: String,
) -> Correction {
  let input =
    "Resposta da agente:\n"
    <> string.trim(reply)
    <> "\n\nMensagem seguinte da pessoa:\n"
    <> string.trim(message)
  case
    decision.decide(
      settings.transport,
      settings.api_key,
      input,
      [#("corrige", question)],
      settings.gate_timeout_ms,
    )
  {
    Error(error) -> Unknown(error)
    Ok(answers) -> {
      settings.charge(principal, answers.input_tokens, 0)
      case dict.get(answers.probabilities, "corrige") |> result.unwrap(0.0) {
        p if p >=. 0.5 -> Corrected
        _ -> NotCorrected
      }
    }
  }
}

fn key(principal: String) -> #(String, String) {
  #("memory_recalled", principal)
}

@external(erlang, "supernova_known_ffi", "get")
fn known_get(key: #(String, String)) -> Result(Bool, Nil)

@external(erlang, "supernova_known_ffi", "put")
fn known_put(key: #(String, String), value: Bool) -> Nil

@external(erlang, "supernova_known_ffi", "delete")
fn known_delete(key: #(String, String)) -> Nil
