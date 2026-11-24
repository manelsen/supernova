//// The gate and the pre-search (docs/prd/PRD-M-memoria.md, 6.3 and 6.5).
////
//// Before the first LLM call of a turn, the Gemini Decision API reads only
//// the message that arrived and says whether it asks about the past of the
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
import supernova/memory/decision
import supernova/memory/recall
import supernova/memory/runtime

/// The question, measured on the bench: 15/15 questions about the past and
/// 0/30 ordinary messages it was not tuned on. A wider one ("does the agent
/// need to remember something?") fired on 8 of 10 ordinary messages.
pub const question =
  "Esta mensagem é uma pergunta sobre o passado da conversa (algo que a pessoa disse, contou ou combinou antes)?"

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
  case text == "" || string.starts_with(text, "/"), settings.within_budget() {
    True, _ -> Skipped
    False, False -> OverBudget
    False, True ->
      case
        decision.decide(
          settings.transport,
          settings.api_key,
          framing <> text,
          [#("passado", question)],
          settings.gate_timeout_ms,
        )
      {
        Error(error) -> Failed(error)
        Ok(answers) -> {
          settings.charge(principal, answers.input_tokens, 0)
          let p =
            dict.get(answers.probabilities, "passado") |> result.unwrap(0.0)
          case p >=. settings.gate_threshold {
            True -> Fired(p)
            False -> Quiet(p)
          }
        }
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
  let started = now_ms()
  let verdict = ask_for(settings, principal, message)
  let gate_ms = now_ms() - started
  case verdict {
    Fired(_) -> {
      let subject = string.trim(message)
      let recall_started = now_ms()
      let outcome =
        recall.recall(settings, data_dir, principal, offset, subject)
      #(
        list.append(messages, recalled(subject, outcome.text)),
        Some(Report(
          verdict: verdict,
          gate_ms: gate_ms,
          recall: Some(outcome),
          recall_ms: now_ms() - recall_started,
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
      )),
    )
  }
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
