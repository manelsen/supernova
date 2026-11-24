//// `lembrar`: whether the person and the agent already talked about
//// something, and where (docs/prd/PRD-M-memoria.md, 6.4).
////
//// What was said (user and agent messages, every chat of the person) is cut
//// into excerpts of 10 messages. A short list of excerpts, the 30 nearest by
//// vector and the 10 sharing most words with the subject, goes to the
//// Gemini Decision API in a compact form, with one general question ("did
//// they talk about it?") and one per excerpt. The answer opens with a tone
//// set by the general probability and shows up to 3 excerpts word for
//// word.
////
//// The vectors live in `conversations/recall.idx`, next to the
//// conversations: `/esquecer` removes the directory, index and all. The
//// file does not end in `.jsonl`, so `buscar_conversa` never reads it.
//// Each excerpt is embedded once, keyed by a hash of its text; the open
//// (last) excerpt gets a new vector when it changes.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import supernova/agenda/schedule
import supernova/core/session/history_store
import supernova/memory/decision
import supernova/memory/runtime
import supernova/tools/buscar_conversa

/// Messages per excerpt.
pub const excerpt_size = 10

/// Excerpts proposed by the vector, and by shared words.
pub const by_vector = 30

pub const by_words = 10

/// Excerpts shown, at most; the least probability to show one, and the tone
/// bands, are the provider's (runtime.Thresholds).
pub const shown = 3

/// Input tokens a `lembrar` is admitted for: the short list in compact form
/// (~6 thousand on the bench, ~11 thousand on LongMemEval), with room.
const recall_estimate = 20_000

/// Embedding requests at the same time while indexing.
const index_workers = 4

/// The general question; `{m}` is the subject.
pub const general_question =
  "Nesta conversa, a pessoa já contou à agente, ou as duas já conversaram, sobre o que esta mensagem pergunta? Mensagem: «{m}»"

/// What one call did, for the ledger and the metrics; `text` is what the
/// agent reads.
pub type Outcome {
  Outcome(
    text: String,
    probability: Option(Float),
    /// "unlikely", "maybe", "likely", or "none" without a probability.
    band: String,
    shortlist: Int,
    decision_tokens: Int,
    embed_tokens: Int,
    /// What the call cost, in millionths of a dollar.
    cost_microusd: Int,
    failure: Option(decision.DecisionError),
  )
}

/// One excerpt: its position and its messages.
pub type Excerpt {
  Excerpt(index: Int, messages: List(history_store.StoredMessage))
}

pub fn index_path(data_dir: String, principal: String) -> String {
  history_store.dir(data_dir, principal) <> "/recall.idx"
}

/// Recall `subject` in what `principal` said, bounded by the settings'
/// timeout. Never fails: a failure becomes a text that points the agent to
/// `buscar_conversa` (I6).
pub fn recall(
  settings: runtime.Settings,
  data_dir: String,
  principal: String,
  offset: Int,
  subject: String,
) -> Outcome {
  let subject = string.trim(subject)
  case subject, settings.admit(principal, recall_estimate) {
    "", Ok(settle) -> {
      settle(0, 0)
      plain("lembrar precisa de um assunto.")
    }
    "", Error(Nil) -> plain("lembrar precisa de um assunto.")
    _, Error(Nil) ->
      plain(
        "lembrar indisponível hoje: o limite de gasto do dia foi atingido. Procure com buscar_conversa, usando palavras do assunto.",
      )
    subject, Ok(settle) -> {
      let outcome = case
        decision.within(settings.recall_timeout_ms, fn() {
          run(settings, data_dir, principal, offset, subject)
        })
      {
        Ok(outcome) -> outcome
        Error(Nil) -> failed(decision.TimedOut, 0, 0)
      }
      settle(outcome.decision_tokens, outcome.embed_tokens)
      let cost =
        microusd(
          outcome.decision_tokens,
          decision.decision_usd_per_million(settings.endpoint.provider),
        )
        + microusd(
          outcome.embed_tokens,
          decision.embed_usd_per_million(settings.endpoint.provider),
        )
      Outcome(..outcome, cost_microusd: cost)
    }
  }
}

fn run(
  settings: runtime.Settings,
  data_dir: String,
  principal: String,
  offset: Int,
  subject: String,
) -> Outcome {
  case said(data_dir, principal) {
    Error(reason) -> plain("lembrar não conseguiu ler as conversas: " <> reason)
    Ok([]) ->
      plain(
        "Vocês ainda não têm conversas guardadas além das mensagens que você vê.",
      )
    Ok(messages) -> {
      let excerpts = excerpts(messages)
      let compact = list.map(excerpts, compact_text(_, offset))
      let #(vectors, embedded) =
        vectors(settings, index_path(data_dir, principal), compact)
      case
        decision.embed(
          settings.transport,
          settings.endpoint,
          subject,
          decision.Query,
          settings.recall_timeout_ms,
        )
      {
        Error(error) -> failed(error, 0, embedded)
        Ok(query) -> {
          let list =
            shortlist(subject, compact, fn(position) {
              case dict.get(vectors, position) {
                Ok(vector) -> Some(cosine(query, vector))
                Error(Nil) -> None
              }
            })
          decide(
            settings,
            excerpts,
            compact,
            list,
            subject,
            offset,
            embedded + decision.estimate_tokens(subject),
          )
        }
      }
    }
  }
}

fn decide(
  settings: runtime.Settings,
  excerpts: List(Excerpt),
  compact: List(String),
  list: List(Int),
  subject: String,
  offset: Int,
  embedded: Int,
) -> Outcome {
  let compact_at = dict.from_list(list.index_map(compact, fn(t, i) { #(i, t) }))
  let input =
    list
    |> list.filter_map(fn(position) { dict.get(compact_at, position) })
    |> string.join("\n\n")
  let questions = [
    decision.YesNo("falado", string.replace(general_question, "{m}", subject)),
    ..list.map(list, fn(position) {
      decision.YesNo(
        "t" <> int.to_string(position + 1),
        "O Trecho "
          <> int.to_string(position + 1)
          <> " fala sobre o que esta mensagem pergunta? Mensagem: «"
          <> subject
          <> "»",
      )
    })
  ]
  case
    decision.decide(
      settings.transport,
      settings.endpoint,
      input,
      questions,
      settings.recall_timeout_ms,
    )
  {
    Error(error) -> failed(error, 0, embedded)
    Ok(answers) -> {
      let general = dict.get(answers.yes, "falado") |> result.unwrap(0.0)
      let excerpt_at =
        dict.from_list(list.map(excerpts, fn(e) { #(e.index, e) }))
      let best =
        list
        |> list.filter_map(fn(position) {
          case dict.get(answers.yes, "t" <> int.to_string(position + 1)) {
            Ok(p) if p >=. settings.thresholds.shown_from -> Ok(#(p, position))
            _ -> Error(Nil)
          }
        })
        |> list.sort(fn(a, b) { float.compare(b.0, a.0) })
        |> list.take(shown)
        |> list.sort(fn(a, b) { int.compare(a.1, b.1) })
      let parts = case best {
        [] -> [
          tone(settings.thresholds, general),
          "Nenhum trecho parece falar disso.",
        ]
        _ ->
          list.flatten([
            [tone(settings.thresholds, general), "Trechos mais prováveis:"],
            list.filter_map(best, fn(item) {
              dict.get(excerpt_at, item.1)
              |> result.map(fn(excerpt) {
                "(probabilidade "
                <> two(item.0)
                <> ")\n"
                <> full_text(excerpt, offset)
              })
            }),
            [buscar_conversa.found_hint],
          ])
      }
      Outcome(
        text: string.join(parts, "\n\n"),
        probability: Some(general),
        band: band(settings.thresholds, general),
        shortlist: list.length(list),
        decision_tokens: answers.input_tokens,
        embed_tokens: embedded,
        cost_microusd: 0,
        failure: None,
      )
    }
  }
}

/// The band of the general probability, for the metrics.
pub fn band(thresholds: runtime.Thresholds, probability: Float) -> String {
  case
    probability <. thresholds.unlikely_below,
    probability <. thresholds.likely_from
  {
    True, _ -> "unlikely"
    False, True -> "maybe"
    False, False -> "likely"
  }
}

/// The tone of the answer, from the general probability.
pub fn tone(thresholds: runtime.Thresholds, probability: Float) -> String {
  case
    probability <. thresholds.unlikely_below,
    probability <. thresholds.likely_from
  {
    True, _ ->
      "Pouco provável que vocês tenham falado disso (probabilidade "
      <> two(probability)
      <> "). Diga que acha que não, sem afirmar com certeza que nunca foi dito."
    False, True ->
      "Talvez vocês tenham falado disso (probabilidade "
      <> two(probability)
      <> "). Se os trechos abaixo não respondem, diga que não se lembra bem e pergunte."
    False, False ->
      "Provável que vocês já tenham falado disso (probabilidade "
      <> two(probability)
      <> ")."
  }
}

fn plain(text: String) -> Outcome {
  Outcome(
    text: text,
    probability: None,
    band: "none",
    shortlist: 0,
    decision_tokens: 0,
    embed_tokens: 0,
    cost_microusd: 0,
    failure: None,
  )
}

/// Tokens × US$ per million, in millionths of a dollar.
fn microusd(tokens: Int, usd_per_million: Float) -> Int {
  float.round(int.to_float(tokens) *. usd_per_million)
}

fn failed(
  error: decision.DecisionError,
  tokens: Int,
  embedded: Int,
) -> Outcome {
  let why = case error {
    decision.Blocked(_) ->
      "o serviço de memória recusou ler estas conversas (filtro de segurança)"
    decision.TimedOut -> "a memória demorou demais"
    _ -> "a memória não respondeu"
  }
  Outcome(
    text: "lembrar indisponível agora: "
      <> why
      <> ". Procure com buscar_conversa, usando palavras do assunto.",
    probability: None,
    band: "none",
    shortlist: 0,
    decision_tokens: tokens,
    embed_tokens: embedded,
    cost_microusd: 0,
    failure: Some(error),
  )
}

// ---------------------------------------------------------------- excerpts

/// What was said, every chat, oldest first.
pub fn said(
  data_dir: String,
  principal: String,
) -> Result(List(history_store.StoredMessage), String) {
  let dir = history_store.dir(data_dir, principal)
  use files <- result.try(case list_dir(dir) {
    Ok(files) -> Ok(files)
    Error(reason) ->
      case history_store.is_missing(reason) {
        True -> Ok([])
        False -> Error(reason)
      }
  })
  files
  |> list.filter(string.ends_with(_, ".jsonl"))
  |> list.try_map(fn(file) {
    history_store.read_file_strict(dir <> "/" <> file)
  })
  |> result.map(fn(per_file) {
    list.flatten(per_file)
    |> list.filter(fn(m) { m.role == "user" || m.role == "assistant" })
    |> list.sort(fn(a, b) { int.compare(a.at, b.at) })
  })
}

pub fn excerpts(messages: List(history_store.StoredMessage)) -> List(Excerpt) {
  messages
  |> list.sized_chunk(excerpt_size)
  |> list.index_map(fn(chunk, i) { Excerpt(index: i, messages: chunk) })
}

/// The date once per excerpt (and again when the day changes), P:/A:.
pub fn compact_text(excerpt: Excerpt, offset: Int) -> String {
  let #(lines, _) =
    list.fold(excerpt.messages, #([], ""), fn(acc, message) {
      let #(lines, day) = acc
      let today = date(message.at, offset)
      let lines = case day == "" || today == day {
        True -> lines
        False -> ["(" <> today <> ")", ..lines]
      }
      let who = case message.role {
        "user" -> "P: "
        _ -> "A: "
      }
      #([who <> flat(message.content), ..lines], today)
    })
  let first = case excerpt.messages {
    [m, ..] -> date(m.at, offset)
    [] -> ""
  }
  string.join(
    [
      "### Trecho " <> int.to_string(excerpt.index + 1) <> ", " <> first,
      ..list.reverse(lines)
    ],
    "\n",
  )
}

/// Word for word, with date, time and who said it, as the agent reads it.
pub fn full_text(excerpt: Excerpt, offset: Int) -> String {
  string.join(
    [
      "### Trecho " <> int.to_string(excerpt.index + 1),
      ..list.map(excerpt.messages, fn(message) {
        let who = case message.role {
          "user" -> "pessoa"
          _ -> "você"
        }
        "["
        <> schedule.format_local(message.at, offset)
        <> "] "
        <> who
        <> ": "
        <> flat(message.content)
      })
    ],
    "\n",
  )
}

fn date(at: Int, offset: Int) -> String {
  string.slice(schedule.format_local(at, offset), 0, 10)
}

fn flat(text: String) -> String {
  string.replace(text, "\n", " ")
}

// ---------------------------------------------------------------- short list

/// The nearest `by_vector` excerpts (those with a vector) and the
/// `by_words` sharing most words with `subject`, in order of time.
pub fn shortlist(
  subject: String,
  compact: List(String),
  similarity: fn(Int) -> Option(Float),
) -> List(Int) {
  let positions = list.index_map(compact, fn(_, i) { i })
  let near =
    positions
    |> list.filter_map(fn(i) {
      case similarity(i) {
        Some(s) -> Ok(#(s, i))
        None -> Error(Nil)
      }
    })
    |> list.sort(fn(a, b) { float.compare(b.0, a.0) })
    |> list.take(by_vector)
    |> list.map(fn(pair) { pair.1 })
  let wanted = set.from_list(words(subject))
  let shared =
    compact
    |> list.index_map(fn(text, i) {
      #(set.size(set.intersection(wanted, set.from_list(words(text)))), i)
    })
    |> list.filter(fn(pair) { pair.0 > 0 })
    // More words first; among equals, the most recent.
    |> list.sort(fn(a, b) {
      case int.compare(b.0, a.0) {
        order.Eq -> int.compare(b.1, a.1)
        other -> other
      }
    })
    |> list.take(by_words)
    |> list.map(fn(pair) { pair.1 })
  list.append(near, shared)
  |> list.unique
  |> list.sort(int.compare)
}

/// Words of 4 letters or more, folded, cut to 5 letters ("consulta" and
/// "consultas" meet; "sessão" and "sessões" do not, which is what the
/// vector is for), without the commonest ones.
pub fn words(text: String) -> List(String) {
  buscar_conversa.fold(text)
  |> string.to_graphemes
  |> list.map(fn(g) {
    case is_word_char(g) {
      True -> g
      False -> " "
    }
  })
  |> string.concat
  |> string.split(" ")
  |> list.filter(fn(w) { string.length(w) >= 4 && !list.contains(stopwords, w) })
  |> list.map(string.slice(_, 0, 5))
}

fn is_word_char(g: String) -> Bool {
  case g {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9" -> True
    _ -> False
  }
}

const stopwords = [
  "para", "pela", "pelo", "com", "sem", "minha", "meus", "minhas", "mesmo",
  "qual", "quais", "quando", "como", "onde", "porque", "sobre", "aquela",
  "aquele", "daquela", "daquele", "lembra", "voce", "ainda", "isso", "disso",
  "nisso", "esse", "essa", "este", "esta", "eles", "elas", "tambem", "muito",
  "mais", "foi", "era", "seu", "sua",
]

pub fn cosine(a: List(Float), b: List(Float)) -> Float {
  let dot = list.zip(a, b) |> list.fold(0.0, fn(acc, p) { acc +. p.0 *. p.1 })
  let norm = fn(v: List(Float)) {
    list.fold(v, 0.0, fn(acc, x) { acc +. x *. x })
    |> float.square_root
    |> result.unwrap(0.0)
  }
  case norm(a) *. norm(b) {
    0.0 -> 0.0
    n -> dot /. n
  }
}

// ---------------------------------------------------------------- index

/// The vector of every excerpt, by position: read from the index, the
/// missing ones embedded (in batches, several at a time) and appended to it.
/// A vector is keyed by the embedding model and the text, so a change of
/// provider builds a new index instead of mixing vectors. An excerpt whose
/// embedding fails simply has no vector this time. Returns the tokens
/// embedded, for the ledger.
fn vectors(
  settings: runtime.Settings,
  path: String,
  compact: List(String),
) -> #(Dict(Int, List(Float)), Int) {
  let known = read_index(path)
  let model = settings.endpoint.embed_model
  let keyed =
    list.index_map(compact, fn(text, i) {
      #(i, hash(model <> "\n" <> text), text)
    })
  let missing = list.filter(keyed, fn(item) { !dict.has_key(known, item.1) })
  let batches =
    parallel(
      list.sized_chunk(missing, decision.embed_batch),
      index_workers,
      fn(batch) {
        decision.embed_many(
          settings.transport,
          settings.endpoint,
          list.map(batch, fn(item) { item.2 }),
          decision.Document,
          settings.recall_timeout_ms,
        )
        |> result.map(fn(answer) {
          let #(vectors, tokens) = answer
          let pairs =
            list.zip(batch, vectors)
            |> list.map(fn(pair) { #(pair.0.1, pair.1) })
          let _ =
            append_file(
              path,
              pairs
                |> list.map(fn(p) { index_line(p.0, p.1) })
                |> string.concat,
            )
          #(pairs, tokens)
        })
      },
    )
    |> list.filter_map(fn(r) { r })
  let fresh = list.flat_map(batches, fn(b) { b.0 })
  let all = dict.merge(known, dict.from_list(fresh))
  let by_position =
    list.filter_map(keyed, fn(item) {
      dict.get(all, item.1) |> result.map(fn(v) { #(item.0, v) })
    })
    |> dict.from_list
  #(by_position, list.fold(batches, 0, fn(sum, b) { sum + b.1 }))
}

fn read_index(path: String) -> Dict(String, List(Float)) {
  let decoder = {
    use h <- decode.field("h", decode.string)
    use v <- decode.field(
      "v",
      decode.list(
        decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)]),
      ),
    )
    decode.success(#(h, v))
  }
  case read_file(path) {
    Error(_) -> dict.new()
    Ok(text) ->
      string.split(text, "\n")
      |> list.filter_map(fn(line) {
        json.parse(line, decoder) |> result.replace_error(Nil)
      })
      |> dict.from_list
  }
}

fn index_line(h: String, vector: List(Float)) -> String {
  json.object([
    #("h", json.string(h)),
    #("v", json.array(vector, json.float)),
  ])
  |> json.to_string
  <> "\n"
}

fn hash(text: String) -> String {
  crypto_hash(atom.create("sha"), bit_array.from_string(text))
  |> bit_array.base16_encode
}

/// `work` over `items`, at most `workers` at a time, results in order.
fn parallel(items: List(a), workers: Int, work: fn(a) -> b) -> List(b) {
  items
  |> list.sized_chunk(workers)
  |> list.flat_map(fn(batch) {
    let replies =
      list.map(batch, fn(item) {
        let reply = process.new_subject()
        let _ = process.spawn(fn() { process.send(reply, work(item)) })
        reply
      })
    list.map(replies, fn(reply) { process.receive_forever(reply) })
  })
}

fn two(p: Float) -> String {
  float.to_string(float.to_precision(p, 2))
  |> fn(s) {
    case string.split(s, ".") {
      [whole, frac] -> whole <> "." <> string.pad_end(frac, 2, "0")
      _ -> s
    }
  }
}

@external(erlang, "crypto", "hash")
fn crypto_hash(kind: atom.Atom, data: BitArray) -> BitArray

@external(erlang, "supernova_file_system_ffi", "list_dir")
fn list_dir(path: String) -> Result(List(String), String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "append_file")
fn append_file(path: String, content: String) -> Result(Nil, String)
