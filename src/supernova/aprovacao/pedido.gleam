//// A request for approval as the person sees and answers it (PRD-K, K-02).
////
//// Pure: the text, the buttons, and the reading of an answer. The code,
//// not the model, recognises the answer (K1): a button, or a short message
//// typed or spoken ("sim", "não 3", "sempre"). Anything longer goes to the
//// agent as any message, and the request keeps waiting.
////
//// The first sentence of every request is the code's (K7, K-I5): the
//// summary the gate wrote. The agent's explanation comes after it.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port
import supernova/self/aprovacoes.{
  type Decision, type Request, Approve, Approved, Cancelled, Expired, Pending,
  Permanent, Refuse, Refused, Window,
}

pub type Choice {
  Yes
  No
  Always
}

/// An answer, with the request's number when the person gave one.
pub type Answer {
  Answer(choice: Choice, number: Option(Int), duration: Option(Duration))
}

/// How long a "yes" lasts, for requests that let the person choose (using
/// a site, K-06): an hour unless they say a day.
pub type Duration {
  Hour
  Day
}

fn windowed(request: Request) -> Bool {
  case request.approve {
    Window(_) -> True
    _ -> False
  }
}

pub type Resolution {
  Decide(id: Int, decision: Decision)
  /// Not decidable as given; tell the person this.
  Explain(String)
}

const action_prefix = "aprovacao:"

// ============================================================================
// What the person sees
// ============================================================================

/// The request's text. `alone` says whether it is the only one waiting:
/// then a bare "sim" answers it; otherwise the answer carries the number.
pub fn message(request: Request, alone alone: Bool) -> String {
  let number = int.to_string(request.id)
  let suffix = case alone {
    True -> ""
    False -> " " <> number
  }
  let always = case request.always {
    True ->
      "; ou sim sempre"
      <> suffix
      <> ", para não perguntar de novo sobre "
      <> target_words(request.target)
    False -> ""
  }
  let how = case windowed(request) {
    True ->
      ". Responda sim"
      <> suffix
      <> " (vale 1 hora), sim"
      <> suffix
      <> " 24 horas"
      <> always
      <> "; ou não"
      <> suffix
    False -> ". Responda sim" <> suffix <> " ou não" <> suffix <> always
  }
  [
    request.summary,
    request.explanation,
    "Pedido " <> number <> how <> ", por texto ou voz. Espero até 24 horas.",
  ]
  |> list.map(string.trim)
  |> list.filter(fn(part) { part != "" })
  |> string.join("\n\n")
}

/// The reminder, three hours in (K6).
pub fn reminder(request: Request, alone alone: Bool) -> String {
  "Lembrete: ainda espero sua resposta.\n\n" <> message(request, alone: alone)
}

/// The longest first sentence (PRD-K, quality gates): what a screen reader
/// says before anything else.
pub const first_sentence_max = 140

/// A first sentence cut to fit, ending in a period.
pub fn first_sentence(text: String) -> String {
  let text = string.trim(text)
  case string.length(text) <= first_sentence_max {
    True -> text
    False -> string.slice(text, 0, first_sentence_max - 2) <> "…."
  }
}

/// The target as the person reads it: `site:a.com` is a.com.
fn target_words(target: String) -> String {
  case string.split_once(target, ":") {
    Ok(#(_, rest)) -> rest
    Error(Nil) -> target
  }
}

/// What the person hears back once the code decided, with how long a
/// yes lasts when they chose it.
pub fn decided_with(request: Request, decision: Decision) -> String {
  case request.status, decision {
    Approved, Approve(Window(ms)) if ms == aprovacoes.one_hour_ms ->
      "Aprovado por 1 hora: " <> request.summary
    Approved, Approve(Window(_)) -> "Aprovado por 24 horas: " <> request.summary
    Approved, Approve(Permanent) ->
      "Aprovado para sempre: "
      <> request.summary
      <> " Para desfazer: /permissoes."
    _, _ -> decided_text(request)
  }
}

/// What the person hears back once the code decided.
pub fn decided_text(request: Request) -> String {
  case request.status {
    Approved ->
      "Aprovado: "
      <> request.summary
      <> " Para ver ou desfazer permissões: /permissoes."
    Refused -> "Recusado: " <> request.summary
    Expired ->
      "O pedido "
      <> int.to_string(request.id)
      <> " expirou sem resposta e conta como recusado: "
      <> request.summary
    Cancelled ->
      "O pedido "
      <> int.to_string(request.id)
      <> " foi cancelado: a tarefa acabou."
    Pending -> request.summary
  }
}

/// Buttons, for the channels that have them: Aprovar, Recusar, and Sempre
/// when the request takes it.
pub fn buttons(request: Request) -> port.ChannelInteractiveReply {
  let action = fn(word) {
    action_prefix <> int.to_string(request.id) <> ":" <> word
  }
  let always = case request.always {
    True -> [
      port.button(
        label: "Sempre",
        action_id: action("sempre"),
        style: port.ButtonSecondary,
      ),
    ]
    False -> []
  }
  let yes = case windowed(request) {
    True -> [
      port.button(
        label: "1 hora",
        action_id: action("hora"),
        style: port.ButtonSuccess,
      ),
      port.button(
        label: "24 horas",
        action_id: action("dia"),
        style: port.ButtonPrimary,
      ),
    ]
    False -> [
      port.button(
        label: "Aprovar",
        action_id: action("sim"),
        style: port.ButtonSuccess,
      ),
    ]
  }
  port.ChannelInteractiveReply([
    port.buttons_block(
      list.flatten([
        yes,
        always,
        [
          port.button(
            label: "Recusar",
            action_id: action("nao"),
            style: port.ButtonDanger,
          ),
        ],
      ]),
    ),
  ])
}

/// A pressed button, read back. Anything else is not an approval button.
pub fn parse_action(action_id: String) -> Option(Answer) {
  case string.split(action_id, ":") {
    ["aprovacao", number, "hora"] ->
      int.parse(number)
      |> option.from_result
      |> option.map(fn(id) { Answer(Yes, Some(id), Some(Hour)) })
    ["aprovacao", number, "dia"] ->
      int.parse(number)
      |> option.from_result
      |> option.map(fn(id) { Answer(Yes, Some(id), Some(Day)) })
    ["aprovacao", number, word] ->
      case int.parse(number), choice_of(word) {
        Ok(id), Some(choice) -> Some(Answer(choice, Some(id), None))
        _, _ -> None
      }
    _ -> None
  }
}

// ============================================================================
// What the agent hears
// ============================================================================

/// The tool's answer when a request was opened.
pub fn asked_note(request: Request, in_group in_group: Bool) -> String {
  let where = case in_group {
    True ->
      " O pedido foi para o privado da pessoa; aqui no grupo, diga só que pediu confirmação no privado."
    False -> ""
  }
  "Pedi aprovação ("
  <> int.to_string(request.id)
  <> "): "
  <> request.summary
  <> where
  <> " Espere a resposta; ela chega como mensagem."
}

/// The outcome, injected into the chat the request was born in.
pub fn outcome_note(request: Request) -> String {
  let head = "[Aprovação " <> int.to_string(request.id) <> "] "
  case request.status {
    Approved -> head <> "aprovada: " <> request.summary
    Refused -> head <> "recusada pela pessoa: " <> request.summary
    Expired ->
      head
      <> "expirou sem resposta em 24 horas e conta como recusada: "
      <> request.summary
    Cancelled -> head <> "cancelada: " <> request.summary
    Pending -> head <> "pendente: " <> request.summary
  }
}

// ============================================================================
// Reading an answer
// ============================================================================

/// A short answer, typed or spoken, or None when the message is anything
/// else. A forwarded voice note is someone else's voice and never counts
/// (K-I2).
pub fn parse(content: String) -> Option(Answer) {
  case spoken(content) {
    Error(Nil) -> None
    Ok(text) -> {
      let words =
        text
        |> fold
        |> string.to_graphemes
        |> list.map(fn(g) {
          case is_word_char(g) {
            True -> g
            False -> " "
          }
        })
        |> string.concat
        |> string.split(" ")
        |> list.filter(fn(w) { w != "" })
        // "sim, pedido 3", "sim número 3"
        |> list.filter(fn(w) { w != "pedido" && w != "numero" })
      // "sim sempre" is "sempre".
      let words = case words {
        ["sim", "sempre", ..rest] -> ["sempre", ..rest]
        _ -> words
      }
      let #(words, duration) = duration_of(words)
      let answer = case words {
        [word] -> option.map(choice_of(word), fn(c) { Answer(c, None, None) })
        [word, number] ->
          case choice_of(word), number_of(number) {
            Some(choice), Some(n) -> Some(Answer(choice, Some(n), None))
            _, _ -> None
          }
        _ -> None
      }
      // A duration goes only with a yes.
      case answer, duration {
        Some(Answer(Yes, n, _)), Some(d) -> Some(Answer(Yes, n, Some(d)))
        _, Some(_) -> None
        _, None -> answer
      }
    }
  }
}

/// "1 hora", "uma hora", "24 horas", "vinte e quatro horas", "um dia" at
/// the end of an answer: taken off, and given back as a duration.
fn duration_of(words: List(String)) -> #(List(String), Option(Duration)) {
  case list.reverse(words) {
    ["dia", "um", ..rest] | ["dia", "1", ..rest] | ["dia", ..rest] -> #(
      list.reverse(rest),
      Some(Day),
    )
    ["horas", "24", ..rest] | ["horas", "quatro", "e", "vinte", ..rest] -> #(
      list.reverse(rest),
      Some(Day),
    )
    ["hora", "uma", ..rest]
    | ["hora", "1", ..rest]
    | ["hora", "um", ..rest]
    | ["hora", ..rest] -> #(list.reverse(rest), Some(Hour))
    _ -> #(words, None)
  }
}

/// The text of the message, or of the person's own voice note.
fn spoken(content: String) -> Result(String, Nil) {
  let content = string.trim(content)
  case string.starts_with(content, "[") {
    False -> Ok(content)
    True ->
      case string.split_once(content, "]\n") {
        Ok(#(heading, text)) ->
          case
            string.starts_with(heading, "[mensagem de voz")
            && string.ends_with(heading, ", transcrita")
            && !string.contains(heading, "encaminhad")
          {
            True -> Ok(text)
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
  }
}

fn is_word_char(g: String) -> Bool {
  case g {
    " " | "," | "." | "!" | "?" | ";" | ":" | "#" | "\n" | "\t" | "-" -> False
    _ -> True
  }
}

/// The words of section 3.3 of PRD-K, and nothing else: a yes, a no, or
/// "sempre" ("sim sempre").
fn choice_of(word: String) -> Option(Choice) {
  case word {
    "sim" | "s" | "pode" | "aprovo" | "ok" | "isso" -> Some(Yes)
    "nao" | "n" | "recuso" | "cancela" -> Some(No)
    "sempre" -> Some(Always)
    _ -> None
  }
}

fn number_of(word: String) -> Option(Int) {
  case int.parse(word) {
    Ok(n) if n > 0 -> Some(n)
    Ok(_) -> None
    Error(Nil) ->
      list.index_fold(spoken_numbers, None, fn(found, name, index) {
        case found, name == word {
          None, True -> Some(index + 1)
          _, _ -> found
        }
      })
  }
}

/// How a transcription writes the numbers a person is likely to say.
const spoken_numbers = [
  "um", "dois", "tres", "quatro", "cinco", "seis", "sete", "oito", "nove", "dez",
  "onze", "doze", "treze", "catorze", "quinze", "dezesseis", "dezessete",
  "dezoito", "dezenove", "vinte",
]

// ============================================================================
// Which request
// ============================================================================

/// Match an answer to the person's pending requests.
pub fn resolve(answer: Answer, pending: List(Request)) -> Resolution {
  case answer.number, pending {
    Some(n), _ ->
      case list.find(pending, fn(r) { r.id == n }) {
        Ok(request) -> decision_for(answer, request, False)
        Error(Nil) ->
          Explain(
            "Não há pedido "
            <> int.to_string(n)
            <> " esperando resposta."
            <> listing(pending),
          )
      }
    None, [request] -> decision_for(answer, request, True)
    None, _ ->
      Explain(
        "Há mais de um pedido esperando. Diga o número junto, por exemplo: "
        <> word_of(answer.choice)
        <> " "
        <> first_id(pending)
        <> "."
        <> listing(pending),
      )
  }
}

fn decision_for(answer: Answer, request: Request, alone: Bool) -> Resolution {
  case answer.choice {
    Yes ->
      case request.approve, answer.duration {
        Window(_), Some(Day) ->
          Decide(request.id, Approve(Window(aprovacoes.one_day_ms)))
        Window(_), _ ->
          Decide(request.id, Approve(Window(aprovacoes.one_hour_ms)))
        scope, _ -> Decide(request.id, Approve(scope))
      }
    No -> Decide(request.id, Refuse)
    Always ->
      case request.always {
        True -> Decide(request.id, Approve(Permanent))
        False -> {
          let suffix = case alone {
            True -> ""
            False -> " " <> int.to_string(request.id)
          }
          Explain(
            "O pedido "
            <> int.to_string(request.id)
            <> " não aceita sempre. Responda sim"
            <> suffix
            <> " ou não"
            <> suffix
            <> ".",
          )
        }
      }
  }
}

fn word_of(choice: Choice) -> String {
  case choice {
    Yes -> "sim"
    No -> "não"
    Always -> "sempre"
  }
}

fn first_id(pending: List(Request)) -> String {
  case pending {
    [first, ..] -> int.to_string(first.id)
    [] -> "1"
  }
}

fn listing(pending: List(Request)) -> String {
  case pending {
    [] -> ""
    _ ->
      "\n\nEsperando resposta:\n"
      <> {
        pending
        |> list.map(fn(r) {
          "Pedido " <> int.to_string(r.id) <> ": " <> r.summary
        })
        |> string.join("\n")
      }
  }
}

@external(erlang, "supernova_text_ffi", "fold")
fn fold(text: String) -> String
