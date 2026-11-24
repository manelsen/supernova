//// The Gemini Decision API and the Gemini embeddings, as the memory uses
//// them (docs/prd/PRD-M-memoria.md).
////
//// Decision 1 does not write text: it reads an input and answers closed
//// questions with calibrated probabilities. The memory only asks yes/no
//// ("noul") questions. Embeddings turn a conversation excerpt into a vector
//// for the short list.
////
//// Every call takes the transport, so tests never touch the network, and a
//// timeout of its own: the call runs in a separate process and is killed
//// when the time is up.

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

pub const decisions_url =
  "https://generativelanguage.googleapis.com/v1beta/decisions"

pub const embed_url =
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-2:embedContent"

pub const model = "gemini-decision-1"

/// Dimensions of the vectors kept in the index.
pub const dimensions = 256

/// US$ per million input tokens (paid tier, 11/2026).
pub const decision_usd_per_million = 0.1

pub const embed_usd_per_million = 0.2

/// POST `body` to `url` with `headers`; the status and the body, or why the
/// request could not be made.
pub type Transport =
  fn(String, List(#(String, String)), String) -> Result(#(Int, String), String)

pub type DecisionError {
  /// No answer within the timeout.
  TimedOut
  /// Refused by Google's safety filter ("sensitive words"): the input never
  /// reached the model.
  Blocked(String)
  /// Any other HTTP error, with a one-line summary.
  HttpError(status: Int, summary: String)
  /// The request could not be made.
  Unreachable(String)
  /// A 200 the memory cannot read.
  BadResponse(String)
}

/// Probabilities by question key, and the input tokens billed.
pub type Answers {
  Answers(probabilities: Dict(String, Float), input_tokens: Int)
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

/// Ask yes/no questions about `input`: `questions` are (key, instructions).
pub fn decide(
  transport: Transport,
  api_key: String,
  input: String,
  questions: List(#(String, String)),
  timeout_ms: Int,
) -> Result(Answers, DecisionError) {
  let body =
    json.object([
      #("model", json.string(model)),
      #("input", json.string(input)),
      #(
        "questions",
        json.object(
          list.map(questions, fn(question) {
            #(
              question.0,
              json.object([
                #("type", json.string("noul")),
                #("instructions", json.string(question.1)),
              ]),
            )
          }),
        ),
      ),
    ])
    |> json.to_string
  use #(status, text) <- result.try(post(
    transport,
    decisions_url,
    api_key,
    body,
    timeout_ms,
  ))
  case status {
    200 -> decode_answers(text)
    _ -> Error(http_error(status, text))
  }
}

/// The vector of `text`, with `dimensions` dimensions.
pub fn embed(
  transport: Transport,
  api_key: String,
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
      #("outputDimensionality", json.int(dimensions)),
    ])
    |> json.to_string
  use #(status, response) <- result.try(post(
    transport,
    embed_url,
    api_key,
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

/// Tokens of `text` for the ledger, when the API does not say: Portuguese
/// chat runs at about 2 characters per token in Gemini's count.
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

fn post(
  transport: Transport,
  url: String,
  api_key: String,
  body: String,
  timeout_ms: Int,
) -> Result(#(Int, String), DecisionError) {
  let headers = [
    #("content-type", "application/json"),
    #("x-goog-api-key", api_key),
  ]
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
  let answer = {
    use probability <- decode.field("noul", number())
    decode.success(probability)
  }
  let decoder = {
    use answers <- decode.field("answers", decode.dict(decode.string, answer))
    use tokens <- decode.optional_field(
      "usage",
      0,
      decode.optionally_at(["total_input_tokens"], 0, decode.int),
    )
    decode.success(Answers(probabilities: answers, input_tokens: tokens))
  }
  json.parse(text, decoder)
  |> result.map_error(fn(_) { BadResponse(clip(text)) })
}

/// Floats, also when JSON writes them as integers (0 or 1).
fn number() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

/// The safety filter answers 400 with an "Input blocked" message, or with
/// one of the documented safety codes.
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
