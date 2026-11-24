//// The gate and the pre-search (docs/prd/PRD-M-memoria.md, 6.3 and 6.5).
////
//// Before the first LLM call of a turn, the decision model reads only the
//// message that arrived and says whether it asks about the past of the
//// conversation. When it does, the turn starts with `lembrar` already
//// called with that message as the subject: the model does not have to
//// remember that it can search, which it mostly did not (the bench: 6%).
////
//// The gate never holds a turn longer than its timeout (I1), and any
//// failure lets the turn go on as it would without memory (I6).

import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/llm/provider
import supernova/memory/correction
import supernova/memory/decision
import supernova/memory/recall
import supernova/memory/runtime

/// Gemini's question, measured on the bench: 15/15 questions about the past
/// and 0/30 ordinary messages it was not tuned on, and 20/20 and 0/40 on a
/// second unseen set. A wider one ("does the agent need to remember
/// something?") fired on 8 of 10 ordinary messages.
pub const question =
  "Esta mensagem é uma pergunta sobre o passado da conversa (algo que a pessoa disse, contou ou combinou antes)?"

/// The Decider's question: what the message is, among four kinds. Asked
/// yes/no, the Decider missed implicit questions ("qual é o telefone da
/// clínica?"); as a choice, the two kinds about the past scored 0.67 or more
/// and ordinary messages 0.09 or less on 131 messages, and 20/20 and 0/40
/// on 60 unseen ones (cutoff 0.25).
pub const kinds = [
  #(
    "dado_pessoal",
    "Pergunta por um dado da vida da pessoa que ela teria contado antes (nome, telefone, horário, remédio, endereço, valor, combinado)",
  ),
  #("lembranca", "Pergunta se a agente lembra de algo que as duas conversaram"),
  #(
    "geral",
    "Pergunta de conhecimento geral, conselho, opinião ou pedido de ajuda",
  ),
  #(
    "conversa",
    "Cumprimento, comentário, desabafo ou notícia, sem pergunta sobre o passado",
  ),
]

pub const kinds_question = "O que é esta mensagem?"

/// Input tokens the gate's call is admitted for: one short message.
const gate_estimate = 300

const framing =
  "Mensagem que a pessoa acabou de mandar para a agente de companhia dela:\n"

/// Id of the call the pre-search adds to the turn. Nine letters and digits:
/// some providers accept nothing else.
pub const call_id = "lembrar01"

pub type Verdict {
  /// Asks about the past, with this probability.
  Fired(Float)
  /// Does not.
  Quiet(Float)
  /// Not asked: a command, or an empty message.
  Skipped
  /// Not asked: the day's spend reached the cap.
  OverBudget
  /// The Decision did not answer; the turn goes on without it.
  Failed(decision.DecisionError)
}

/// What the gate and the pre-search did in one turn, for the metrics.
pub type Report {
  Report(
    verdict: Verdict,
    gate_ms: Int,
    recall: Option(recall.Outcome),
    recall_ms: Int,
    /// Whether this message corrects the previous turn's `lembrar`.
    correction: Option(correction.Correction),
  )
}

pub fn ask(settings: runtime.Settings, message: String) -> Verdict {
  ask_for(settings, "", message)
}

/// `ask`, charging the call to `principal`.
pub fn ask_for(
  settings: runtime.Settings,
  principal: String,
  message: String,
) -> Verdict {
  let text = string.trim(message)
  let admitted = case text == "" || string.starts_with(text, "/") {
    True -> Error(Skipped)
    False ->
      settings.admit(principal, gate_estimate)
      |> result.replace_error(OverBudget)
  }
  case admitted {
    Error(verdict) -> verdict
    Ok(settle) ->
      case
        decision.decide(
          settings.transport,
          settings.endpoint,
          framing <> text,
          [gate_question(settings.endpoint.provider)],
          settings.gate_timeout_ms,
        )
      {
        Error(error) -> {
          settle(0, 0)
          Failed(error)
        }
        Ok(answers) -> {
          settle(answers.input_tokens, 0)
          let p = past_probability(answers)
          case p >=. settings.thresholds.gate {
            True -> Fired(p)
            False -> Quiet(p)
          }
        }
      }
  }
}

fn gate_question(provider: decision.Provider) -> decision.Question {
  case provider {
    decision.Gemini -> decision.YesNo("passado", question)
    decision.Perplexity -> decision.Choice("passado", kinds_question, kinds)
  }
}

/// The probability that the message asks about the past: the yes of the
/// yes/no question, or the two kinds about the past of the choice.
fn past_probability(answers: decision.Answers) -> Float {
  case dict.get(answers.yes, "passado") {
    Ok(p) -> p
    Error(Nil) ->
      case dict.get(answers.choices, "passado") {
        Ok(kinds) ->
          { dict.get(kinds, "dado_pessoal") |> result.unwrap(0.0) }
          +. { dict.get(kinds, "lembranca") |> result.unwrap(0.0) }
        Error(Nil) -> 0.0
      }
  }
}

/// The turn's messages with the pre-search added when the gate fires;
/// unchanged otherwise, and always unchanged with the memory off (I5).
pub fn prepare(
  messages: List(provider.ChatMessage),
  message: String,
  data_dir: String,
  principal: String,
  offset: Int,
) -> #(List(provider.ChatMessage), Option(Report)) {
  case runtime.get() {
    None -> #(messages, None)
    Some(settings) ->
      prepare_with(settings, messages, message, data_dir, principal, offset)
  }
}

pub fn prepare_with(
  settings: runtime.Settings,
  messages: List(provider.ChatMessage),
  message: String,
  data_dir: String,
  principal: String,
  offset: Int,
) -> #(List(provider.ChatMessage), Option(Report)) {
  let corrected =
    correction.check(settings, principal, last_reply(messages), message)
  let started = now_ms()
  let verdict = ask_for(settings, principal, message)
  let gate_ms = now_ms() - started
  case verdict {
    Fired(_) -> {
      let subject = string.trim(message)
      let recall_started = now_ms()
      let outcome =
        recall.recall(settings, data_dir, principal, offset, subject)
      correction.mark(principal)
      #(
        list.append(messages, recalled(subject, outcome.text)),
        Some(Report(
          verdict: verdict,
          gate_ms: gate_ms,
          recall: Some(outcome),
          recall_ms: now_ms() - recall_started,
          correction: corrected,
        )),
      )
    }
    _ -> #(
      messages,
      Some(Report(
        verdict: verdict,
        gate_ms: gate_ms,
        recall: None,
        recall_ms: 0,
        correction: corrected,
      )),
    )
  }
}

/// The agent's last reply before the message that arrived.
fn last_reply(messages: List(provider.ChatMessage)) -> Option(String) {
  messages
  |> list.reverse
  |> list.find(fn(m) { m.role == "assistant" && string.trim(m.content) != "" })
  |> option.from_result
  |> option.map(fn(m) { m.content })
}

/// The call to `lembrar` and its result, as if the agent had made it.
pub fn recalled(subject: String, result: String) -> List(provider.ChatMessage) {
  let arguments =
    json.object([#("assunto", json.string(subject))]) |> json.to_string
  [
    provider.ChatMessage(
      role: "assistant",
      content: "",
      tool_call_id: None,
      tool_calls: Some([
        provider.ToolCall(id: call_id, name: "lembrar", arguments: arguments),
      ]),
      reasoning_content: None,
      images: [],
    ),
    provider.ChatMessage(
      role: "tool",
      content: result,
      tool_call_id: Some(call_id),
      tool_calls: None,
      reasoning_content: None,
      images: [],
    ),
  ]
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int
