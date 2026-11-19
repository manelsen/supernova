//// The judge: an LLM scoring what the deterministic checks cannot measure.
////
//// Every score must come with literal transcript evidence. The code verifies
//// each quote against the numbered line it cites; a criterion without a valid
//// quote is inconclusive, never approved.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import supernova/harness/checks
import supernova/harness/scenario.{type Rubric}
import supernova/self/template as prompt_template

pub type Evidence {
  Evidence(line: Int, quote: String)
}

pub type Status {
  Valid
  Inconclusive
}

pub type CriterionResult {
  CriterionResult(
    id: String,
    score: Int,
    status: Status,
    evidence: List(Evidence),
    why: String,
  )
}

pub type Verdict {
  Verdict(ok: Bool, criteria: List(CriterionResult), failures: List(String))
}

// ============================================================================
// Schema and prompt
// ============================================================================

/// JSON schema for `claude --json-schema`, generated from the rubric.
pub fn schema(rubric: Rubric) -> String {
  let ids =
    json.array(list.map(rubric.criteria, fn(item) { item.id }), json.string)
  json.to_string(
    json.object([
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #(
            "criteria",
            json.object([
              #("type", json.string("array")),
              #(
                "items",
                json.object([
                  #("type", json.string("object")),
                  #(
                    "properties",
                    json.object([
                      #(
                        "id",
                        json.object([
                          #("type", json.string("string")),
                          #("enum", ids),
                        ]),
                      ),
                      #(
                        "score",
                        json.object([
                          #("type", json.string("integer")),
                          #("minimum", json.int(0)),
                          #("maximum", json.int(2)),
                        ]),
                      ),
                      #(
                        "evidence",
                        json.object([
                          #("type", json.string("array")),
                          #(
                            "items",
                            json.object([
                              #("type", json.string("object")),
                              #(
                                "properties",
                                json.object([
                                  #(
                                    "line",
                                    json.object([
                                      #("type", json.string("integer")),
                                    ]),
                                  ),
                                  #(
                                    "quote",
                                    json.object([
                                      #("type", json.string("string")),
                                    ]),
                                  ),
                                ]),
                              ),
                              #(
                                "required",
                                json.array(["line", "quote"], json.string),
                              ),
                            ]),
                          ),
                        ]),
                      ),
                      #("why", json.object([#("type", json.string("string"))])),
                    ]),
                  ),
                  #(
                    "required",
                    json.array(["id", "score", "evidence", "why"], json.string),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
      #("required", json.array(["criteria"], json.string)),
    ]),
  )
}

pub fn render_prompt(
  template: String,
  rubric_text: String,
  agents_text: String,
  personas_text: String,
  transcript_text: String,
) -> String {
  // Single pass: a placeholder inside an agent's core or the transcript is
  // never expanded.
  prompt_template.render(template, [
    #("rubric", rubric_text),
    #("agents", agents_text),
    #("personas", personas_text),
    #("transcript", transcript_text),
  ])
}

/// The user turn sent with the judge prompt. Everything the judge needs is in
/// the system prompt (written to a file), so this stays short.
pub const instruction =
  "Julgue o transcript conforme as instruções e responda só com o JSON pedido."

// ============================================================================
// Parse and verify
// ============================================================================

/// Parse one judge answer. `lines` are the transcript lines without numbers;
/// line 1 is the first entry. Invalid answers are retried by the caller.
pub fn parse_answer(
  rubric: Rubric,
  raw: String,
  lines: List(String),
) -> Result(List(CriterionResult), String) {
  let text = strip_fence(raw)
  use payload <- result.try(
    case json.parse(from: text, using: answer_decoder()) {
      Ok(payload) -> Ok(payload)
      Error(_) -> Error("judge answer is not JSON")
    },
  )
  let expected_ids = list.map(rubric.criteria, fn(item) { item.id })
  let actual_ids = list.map(payload, fn(item) { item.id })
  use _ <- result.try(case same_ids(expected_ids, actual_ids) {
    True -> Ok(Nil)
    False ->
      Error(
        "judge answer has wrong criteria: expected "
        <> string.join(expected_ids, ",")
        <> " got "
        <> string.join(actual_ids, ","),
      )
  })
  use _ <- result.try(
    case list.find(payload, fn(item) { item.score < 0 || item.score > 2 }) {
      Ok(item) -> Error("judge score out of range for " <> item.id)
      Error(_) -> Ok(Nil)
    },
  )
  payload
  |> list.map(fn(item) {
    let evidence =
      item.evidence
      |> list.filter(fn(quote) { valid_quote(quote, lines) })
    CriterionResult(
      id: item.id,
      score: item.score,
      status: case evidence {
        [] -> Inconclusive
        _ -> Valid
      },
      evidence: evidence,
      why: item.why,
    )
  })
  |> Ok
}

fn same_ids(expected: List(String), actual: List(String)) -> Bool {
  list.length(expected) == list.length(actual)
  && list.all(expected, fn(id) { list.contains(actual, id) })
}

fn valid_quote(evidence: Evidence, lines: List(String)) -> Bool {
  let quote = evidence.quote
  let length = string.length(quote)
  case length >= 1 && length <= 300 {
    False -> False
    True ->
      case lines |> list.drop(evidence.line - 1) |> list.first {
        Error(_) -> False
        Ok(line) ->
          string.contains(normalize_spaces(line), normalize_spaces(quote))
      }
  }
}

pub fn normalize_spaces(text: String) -> String {
  text
  |> string.replace("\n", " ")
  |> string.replace("\t", " ")
  |> string.split(" ")
  |> list.filter(fn(part) { part != "" })
  |> string.join(" ")
}

fn strip_fence(text: String) -> String {
  let trimmed = string.trim(text)
  case string.starts_with(trimmed, "```") {
    False -> trimmed
    True -> {
      let without_open =
        trimmed
        |> string.split("\n")
        |> list.drop(1)
        |> string.join("\n")
      case string.contains(without_open, "```") {
        True ->
          without_open
          |> string.split("```")
          |> list.first
          |> result.unwrap(without_open)
          |> string.trim
        False -> string.trim(without_open)
      }
    }
  }
}

type AnswerCriterion {
  AnswerCriterion(id: String, score: Int, evidence: List(Evidence), why: String)
}

fn answer_decoder() -> decode.Decoder(List(AnswerCriterion)) {
  use criteria <- decode.field("criteria", decode.list(criterion_decoder()))
  decode.success(criteria)
}

fn criterion_decoder() -> decode.Decoder(AnswerCriterion) {
  use id <- decode.field("id", decode.string)
  use score <- decode.field("score", decode.int)
  use evidence <- decode.field("evidence", decode.list(evidence_decoder()))
  use why <- decode.optional_field("why", "", decode.string)
  decode.success(AnswerCriterion(
    id: id,
    score: score,
    evidence: evidence,
    why: why,
  ))
}

fn evidence_decoder() -> decode.Decoder(Evidence) {
  use line <- decode.field("line", decode.int)
  use quote <- decode.field("quote", decode.string)
  decode.success(Evidence(line: line, quote: quote))
}

// ============================================================================
// Verdict
// ============================================================================

/// A scenario run passes only when every deterministic check passes and every
/// rubric criterion reaches its minimum; a critical criterion may not be
/// inconclusive. `Error` means both judge answers were invalid.
pub fn verdict(
  deterministic: List(checks.CheckResult),
  rubric: Rubric,
  answer: Result(List(CriterionResult), String),
) -> Verdict {
  let deterministic_failures =
    deterministic
    |> list.filter(fn(result) { !result.ok })
    |> list.map(fn(result) {
      "check "
      <> result.check
      <> " failed: "
      <> string.join(result.violations, "; ")
    })
  case answer {
    Error(reason) ->
      Verdict(
        ok: False,
        criteria: [],
        failures: list.append(deterministic_failures, [
          "judge_failed: " <> reason,
        ]),
      )
    Ok(criteria) -> {
      let judge_failures =
        rubric.criteria
        |> list.filter_map(fn(criterion) {
          case list.find(criteria, fn(item) { item.id == criterion.id }) {
            Error(_) -> Ok("judge omitted " <> criterion.id)
            Ok(item) ->
              case item.status {
                Inconclusive ->
                  Ok(
                    criterion.id <> " is inconclusive: evidence does not match",
                  )
                Valid ->
                  case item.score < criterion.minimum {
                    True ->
                      Ok(render_failure(
                        criterion.id,
                        item.score,
                        criterion.minimum,
                        item.evidence,
                      ))
                    False -> Error(Nil)
                  }
              }
          }
        })
      Verdict(
        ok: list.is_empty(deterministic_failures)
          && list.is_empty(judge_failures),
        criteria: criteria,
        failures: list.append(deterministic_failures, judge_failures),
      )
    }
  }
}

fn render_failure(
  id: String,
  score: Int,
  minimum: Int,
  evidence: List(Evidence),
) -> String {
  let citations =
    evidence
    |> list.map(fn(item) {
      "[" <> int.to_string(item.line) <> "] " <> item.quote
    })
    |> string.join(" | ")
  id
  <> " scored "
  <> int.to_string(score)
  <> " below minimum "
  <> int.to_string(minimum)
  <> case citations {
    "" -> ""
    _ -> " — " <> citations
  }
}

/// One retry for an invalid answer. A second failure is `judge_failed`.
pub fn ask(
  rubric: Rubric,
  lines: List(String),
  ask_model: fn() -> Result(String, String),
) -> Result(List(CriterionResult), String) {
  case attempt(rubric, lines, ask_model) {
    Ok(criteria) -> Ok(criteria)
    Error(first) ->
      case attempt(rubric, lines, ask_model) {
        Ok(criteria) -> Ok(criteria)
        Error(second) -> Error(first <> "; retry: " <> second)
      }
  }
}

fn attempt(
  rubric: Rubric,
  lines: List(String),
  ask_model: fn() -> Result(String, String),
) -> Result(List(CriterionResult), String) {
  case ask_model() {
    Error(reason) -> Error(reason)
    Ok(raw) -> parse_answer(rubric, raw, lines)
  }
}
