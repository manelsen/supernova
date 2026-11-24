//// Decision models and embeddings, as the memory uses them
//// (docs/prd/PRD-M-memoria.md).
////
//// A decision model does not write text: it reads an input and answers
//// closed questions with probabilities. Two providers speak the same
//// question format with small differences:
////
//// - Perplexity Decider v1.3 (the default): `state`, `Authorization:
////   Bearer`, `usage.input_tokens`; embeddings `pplx-embed-v2-context-0.6b`
////   (ZDR by default), int8 in base64, many per request.
//// - Gemini Decision 1: `input`, `x-goog-api-key`,
////   `usage.total_input_tokens`; embeddings `gemini-embedding-2`, one per
////   request.
////
//// Every call takes the transport, so tests never touch the network, and a
//// timeout of its own: the call runs in a separate process and is killed
//// when the time is up.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type Provider {
  Perplexity
  Gemini
}

/// Who answers, with which key and models.
pub type Endpoint {
  Endpoint(
    provider: Provider,
    api_key: String,
    decision_model: String,
    embed_model: String,
  )
}

/// The endpoint for `provider` with its default models.
pub fn endpoint(provider: Provider, api_key: String) -> Endpoint {
  case provider {
    Perplexity ->
      Endpoint(
        provider: Perplexity,
        api_key: api_key,
        decision_model: "pplx-decider-v1.3",
        embed_model: "pplx-embed-v2-context-0.6b",
      )
    Gemini ->
      Endpoint(
        provider: Gemini,
        api_key: api_key,
        decision_model: "gemini-decision-1",
        embed_model: "gemini-embedding-2",
      )
  }
}

pub fn provider_name(provider: Provider) -> String {
  case provider {
    Perplexity -> "perplexity"
    Gemini -> "gemini"
  }
}

pub fn decisions_url(provider: Provider) -> String {
  case provider {
    Perplexity -> "https://api.perplexity.ai/v1/decisions"
    Gemini -> "https://generativelanguage.googleapis.com/v1beta/decisions"
  }
}

pub fn embed_url(provider: Provider) -> String {
  case provider {
    Perplexity -> "https://api.perplexity.ai/v1/embeddings"
    Gemini ->
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-2:embedContent"
  }
}

/// US$ per million input tokens (11/2026; outputs are free).
pub fn decision_usd_per_million(provider: Provider) -> Float {
  case provider {
    Perplexity -> 0.02
    Gemini -> 0.1
  }
}

pub fn embed_usd_per_million(provider: Provider) -> Float {
  case provider {
    Perplexity -> 0.02
    Gemini -> 0.2
  }
}

/// Gemini vectors are cut to this many dimensions; Perplexity's 0.6B model
/// only gives 1024.
pub const gemini_dimensions = 256

/// Texts per embeddings request to Perplexity (the API takes up to 512 and
/// 120 thousand tokens).
pub const embed_batch = 32

/// POST `body` to `url` with `headers`; the status and the body, or why the
/// request could not be made.
pub type Transport =
  fn(String, List(#(String, String)), String) -> Result(#(Int, String), String)

pub type DecisionError {
  /// No answer within the timeout.
  TimedOut
  /// Refused by a safety filter ("sensitive words"): the input never
  /// reached the model.
  Blocked(String)
  /// Any other HTTP error, with a one-line summary.
  HttpError(status: Int, summary: String)
  /// The request could not be made.
  Unreachable(String)
  /// A 200 the memory cannot read.
  BadResponse(String)
}

/// A closed question.
pub type Question {
  /// Yes or no: the answer is the probability of yes.
  YesNo(key: String, instructions: String)
  /// One of `options` (name, description): the answer is a probability per
  /// option, summing to 1.
  Choice(key: String, instructions: String, options: List(#(String, String)))
}

/// Probabilities of yes by yes/no key, probabilities per option by choice
/// key, and the input tokens billed.
pub type Answers {
  Answers(
    yes: Dict(String, Float),
    choices: Dict(String, Dict(String, Float)),
    input_tokens: Int,
  )
}

pub type EmbedTask {
  /// An excerpt that goes into the index.
  Document
  /// The question the short list is built for.
  Query
}

pub fn error_summary(error: DecisionError) -> String {
  case error {
    TimedOut -> "timed out"
    Blocked(reason) -> "blocked by the safety filter: " <> reason
    HttpError(status, summary) ->
      "HTTP " <> int.to_string(status) <> ": " <> summary
    Unreachable(reason) -> "unreachable: " <> reason
    BadResponse(reason) -> "unreadable answer: " <> reason
  }
}

/// Ask closed questions about `input`.
pub fn decide(
  transport: Transport,
  endpoint: Endpoint,
  input: String,
  questions: List(Question),
  timeout_ms: Int,
) -> Result(Answers, DecisionError) {
  let input_field = case endpoint.provider {
    Perplexity -> "state"
    Gemini -> "input"
  }
  let body =
    json.object([
      #("model", json.string(endpoint.decision_model)),
      #(input_field, json.string(input)),
      #("questions", json.object(list.map(questions, question_json))),
    ])
    |> json.to_string
  use #(status, text) <- result.try(post(
    transport,
    decisions_url(endpoint.provider),
    headers(endpoint),
    body,
    timeout_ms,
  ))
  case status {
    200 -> decode_answers(text)
    _ -> Error(http_error(status, text))
  }
}

fn question_json(question: Question) -> #(String, json.Json) {
  case question {
    YesNo(key, instructions) -> #(
      key,
      json.object([
        #("type", json.string("noul")),
        #("instructions", json.string(instructions)),
      ]),
    )
    Choice(key, instructions, options) -> #(
      key,
      json.object([
        #("type", json.string("choice")),
        #("instructions", json.string(instructions)),
        #(
          "criteria",
          json.object(
            list.map(options, fn(option) { #(option.0, json.string(option.1)) }),
          ),
        ),
      ]),
    )
  }
}

/// The vectors of `texts`, in order, and the tokens billed (estimated where
/// the provider does not say).
pub fn embed_many(
  transport: Transport,
  endpoint: Endpoint,
  texts: List(String),
  task: EmbedTask,
  timeout_ms: Int,
) -> Result(#(List(List(Float)), Int), DecisionError) {
  case endpoint.provider {
    Perplexity ->
      texts
      |> list.sized_chunk(embed_batch)
      |> list.try_map(embed_perplexity(transport, endpoint, _, task, timeout_ms))
      |> result.map(fn(batches) {
        #(
          list.flat_map(batches, fn(b) { b.0 }),
          list.fold(batches, 0, fn(sum, b) { sum + b.1 }),
        )
      })
    Gemini ->
      texts
      |> list.try_map(embed_gemini(transport, endpoint, _, task, timeout_ms))
      |> result.map(fn(vectors) {
        #(vectors, list.fold(texts, 0, fn(s, t) { s + estimate_tokens(t) }))
      })
  }
}

/// The vector of one text.
pub fn embed(
  transport: Transport,
  endpoint: Endpoint,
  text: String,
  task: EmbedTask,
  timeout_ms: Int,
) -> Result(List(Float), DecisionError) {
  use #(vectors, _) <- result.try(embed_many(
    transport,
    endpoint,
    [text],
    task,
    timeout_ms,
  ))
  case vectors {
    [vector] -> Ok(vector)
    _ -> Error(BadResponse("expected one vector"))
  }
}

fn embed_perplexity(
  transport: Transport,
  endpoint: Endpoint,
  texts: List(String),
  task: EmbedTask,
  timeout_ms: Int,
) -> Result(#(List(List(Float)), Int), DecisionError) {
  let input_type = case task {
    Document -> "document"
    Query -> "query"
  }
  let body =
    json.object([
      #("model", json.string(endpoint.embed_model)),
      #("input", json.array(texts, json.string)),
      #("input_type", json.string(input_type)),
    ])
    |> json.to_string
  use #(status, text) <- result.try(post(
    transport,
    embed_url(Perplexity),
    headers(endpoint),
    body,
    timeout_ms,
  ))
  case status {
    200 -> {
      let item = {
        use index <- decode.field("index", decode.int)
        use vector <- decode.field("embedding", decode.string)
        decode.success(#(index, vector))
      }
      let decoder = {
        use data <- decode.field("data", decode.list(item))
        use tokens <- decode.optional_field(
          "usage",
          0,
          decode.optionally_at(["total_tokens"], 0, decode.int),
        )
        decode.success(#(data, tokens))
      }
      use #(data, tokens) <- result.try(
        json.parse(text, decoder)
        |> result.replace_error(BadResponse(clip(text))),
      )
      use vectors <- result.try(
        data
        |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
        |> list.try_map(fn(item) { int8_vector(item.1) })
        |> result.replace_error(BadResponse("bad base64 vector")),
      )
      Ok(#(vectors, tokens))
    }
    _ -> Error(http_error(status, text))
  }
}

fn embed_gemini(
  transport: Transport,
  endpoint: Endpoint,
  text: String,
  task: EmbedTask,
  timeout_ms: Int,
) -> Result(List(Float), DecisionError) {
  let task_type = case task {
    Document -> "RETRIEVAL_DOCUMENT"
    Query -> "RETRIEVAL_QUERY"
  }
  let body =
    json.object([
      #(
        "content",
        json.object([
          #(
            "parts",
            json.preprocessed_array([
              json.object([#("text", json.string(text))]),
            ]),
          ),
        ]),
      ),
      #("taskType", json.string(task_type)),
      #("outputDimensionality", json.int(gemini_dimensions)),
    ])
    |> json.to_string
  use #(status, response) <- result.try(post(
    transport,
    embed_url(Gemini),
    headers(endpoint),
    body,
    timeout_ms,
  ))
  case status {
    200 -> {
      let decoder = {
        use values <- decode.subfield(
          ["embedding", "values"],
          decode.list(number()),
        )
        decode.success(values)
      }
      json.parse(response, decoder)
      |> result.map_error(fn(_) { BadResponse(clip(response)) })
    }
    _ -> Error(http_error(status, response))
  }
}

/// Signed bytes, one per dimension.
pub fn int8_vector(encoded: String) -> Result(List(Float), Nil) {
  use bytes <- result.try(bit_array.base64_decode(encoded))
  Ok(signed_bytes(bytes, []))
}

fn signed_bytes(bytes: BitArray, acc: List(Float)) -> List(Float) {
  case bytes {
    <<value:signed-size(8), rest:bits>> ->
      signed_bytes(rest, [int.to_float(value), ..acc])
    _ -> list.reverse(acc)
  }
}

/// Tokens of `text` for the ledger, when the API does not say: Portuguese
/// chat runs at about 2 characters per token.
pub fn estimate_tokens(text: String) -> Int {
  string.length(text) / 2 + 1
}

/// The real transport.
pub fn hackney_transport() -> Transport {
  fn(url: String, headers: List(#(String, String)), body: String) {
    use req <- result.try(
      request.to(url) |> result.replace_error("invalid url: " <> url),
    )
    let req =
      req
      |> request.set_method(http.Post)
      |> request.set_body(body)
    let req =
      list.fold(headers, req, fn(r, header) {
        request.set_header(r, header.0, header.1)
      })
    hackney.send(req)
    |> result.map(fn(response) { #(response.status, response.body) })
    |> result.map_error(fn(error) { string.inspect(error) })
  }
}

fn headers(endpoint: Endpoint) -> List(#(String, String)) {
  let auth = case endpoint.provider {
    Perplexity -> #("authorization", "Bearer " <> endpoint.api_key)
    Gemini -> #("x-goog-api-key", endpoint.api_key)
  }
  [#("content-type", "application/json"), auth]
}

fn post(
  transport: Transport,
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
) -> Result(#(Int, String), DecisionError) {
  case within(timeout_ms, fn() { transport(url, headers, body) }) {
    Error(Nil) -> Error(TimedOut)
    Ok(Error(reason)) -> Error(Unreachable(reason))
    Ok(Ok(answer)) -> Ok(answer)
  }
}

/// Run `work` in its own process and wait at most `timeout_ms`; a late
/// worker is killed, so a slow API never piles up processes.
pub fn within(timeout_ms: Int, work: fn() -> a) -> Result(a, Nil) {
  let reply = process.new_subject()
  let worker = process.spawn_unlinked(fn() { process.send(reply, work()) })
  case process.receive(reply, timeout_ms) {
    Ok(value) -> Ok(value)
    Error(Nil) -> {
      process.kill(worker)
      Error(Nil)
    }
  }
}

fn decode_answers(text: String) -> Result(Answers, DecisionError) {
  // A choice carries probabilities per option; a yes/no, its "noul".
  let answer =
    decode.one_of(
      {
        use probabilities <- decode.field(
          "probabilities",
          decode.dict(decode.string, number()),
        )
        decode.success(Error(probabilities))
      },
      [
        {
          use probability <- decode.field("noul", number())
          decode.success(Ok(probability))
        },
      ],
    )
  let decoder = {
    use answers <- decode.field("answers", decode.dict(decode.string, answer))
    use usage <- decode.optional_field(
      "usage",
      dict.new(),
      decode.dict(decode.string, decode.dynamic),
    )
    decode.success(#(answers, usage))
  }
  use #(answers, usage) <- result.try(
    json.parse(text, decoder) |> result.replace_error(BadResponse(clip(text))),
  )
  let yes =
    dict.fold(answers, dict.new(), fn(acc, key, a) {
      case a {
        Ok(p) -> dict.insert(acc, key, p)
        Error(_) -> acc
      }
    })
  let choices =
    dict.fold(answers, dict.new(), fn(acc, key, a) {
      case a {
        Error(ps) -> dict.insert(acc, key, ps)
        Ok(_) -> acc
      }
    })
  // Perplexity says input_tokens; Gemini, total_input_tokens.
  let tokens =
    ["input_tokens", "total_input_tokens"]
    |> list.find_map(fn(key) {
      dict.get(usage, key)
      |> result.try(fn(v) {
        decode.run(v, decode.int) |> result.replace_error(Nil)
      })
    })
    |> result.unwrap(0)
  Ok(Answers(yes: yes, choices: choices, input_tokens: tokens))
}

/// Floats, also when JSON writes them as integers (0 or 1).
fn number() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

/// A safety filter answers 400 with an "Input blocked" message, or with one
/// of the documented safety codes.
fn http_error(status: Int, text: String) -> DecisionError {
  let lowered = string.lowercase(text)
  let blocked =
    string.contains(lowered, "input blocked")
    || list.any(
      [
        "\"safety\"", "\"prohibited_content\"", "\"blocklist\"",
        "\"image_safety\"", "\"content_blocked\"",
      ],
      string.contains(lowered, _),
    )
  case status, blocked {
    400, True -> Blocked(clip(text))
    _, _ -> HttpError(status: status, summary: clip(text))
  }
}

fn clip(text: String) -> String {
  let flat = string.replace(text, "\n", " ")
  case string.length(flat) > 300 {
    True -> string.slice(flat, 0, 300) <> "…"
    False -> flat
  }
}
