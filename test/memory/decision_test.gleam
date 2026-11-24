import gleam/dict
import gleam/erlang/process
import gleam/string
import gleeunit/should
import supernova/memory/decision

fn answering(status: Int, body: String) -> decision.Transport {
  fn(_url, _headers, _body) { Ok(#(status, body)) }
}

pub fn decide_reads_the_probabilities_and_tokens_test() {
  let body =
    "{\"answers\":{\"falado\":{\"type\":\"noul\",\"noul\":0.93,\"confidence\":0.93},\"t1\":{\"type\":\"noul\",\"noul\":1}},\"usage\":{\"total_input_tokens\":6157,\"total_output_tokens\":0}}"
  let assert Ok(answers) =
    decision.decide(
      answering(200, body),
      "k",
      "input",
      [#("falado", "q")],
      1000,
    )
  dict.get(answers.probabilities, "falado") |> should.equal(Ok(0.93))
  // JSON may write a probability as an integer.
  dict.get(answers.probabilities, "t1") |> should.equal(Ok(1.0))
  answers.input_tokens |> should.equal(6157)
}

pub fn decide_sends_noul_questions_with_the_key_test() {
  let seen = process.new_subject()
  let transport = fn(url, headers, body) {
    process.send(seen, #(url, headers, body))
    Ok(#(200, "{\"answers\":{}}"))
  }
  let assert Ok(_) =
    decision.decide(transport, "segredo", "a conversa", [#("q1", "Já?")], 1000)
  let assert Ok(#(url, headers, body)) = process.receive(seen, 1000)
  url |> should.equal(decision.decisions_url)
  headers
  |> should.equal([
    #("content-type", "application/json"),
    #("x-goog-api-key", "segredo"),
  ])
  body |> string.contains("\"model\":\"gemini-decision-1\"") |> should.be_true()
  body |> string.contains("\"input\":\"a conversa\"") |> should.be_true()
  body
  |> string.contains("\"q1\":{\"type\":\"noul\",\"instructions\":\"Já?\"}")
  |> should.be_true()
}

/// A transport that never answers: the call gives up at the timeout.
pub fn decide_times_out_test() {
  let never = fn(_url, _headers, _body) {
    let nothing = process.new_subject()
    let _ = process.receive(nothing, 60_000)
    Ok(#(200, "{}"))
  }
  decision.decide(never, "k", "i", [], 50)
  |> should.equal(Error(decision.TimedOut))
}

pub fn decide_tells_a_safety_block_from_other_errors_test() {
  let blocked =
    "{\"error\":{\"message\":\"Input blocked: The prompt could not be submitted. The prompt contains sensitive words\",\"code\":\"invalid_request\"}}"
  let assert Error(decision.Blocked(_)) =
    decision.decide(answering(400, blocked), "k", "i", [], 1000)
  let assert Error(decision.Blocked(_)) =
    decision.decide(
      answering(400, "{\"error\":{\"code\":\"safety\"}}"),
      "k",
      "i",
      [],
      1000,
    )
  let assert Error(decision.HttpError(429, _)) =
    decision.decide(answering(429, "{\"error\":{}}"), "k", "i", [], 1000)
  let assert Error(decision.HttpError(400, _)) =
    decision.decide(
      answering(400, "{\"error\":{\"message\":\"too many tokens\"}}"),
      "k",
      "i",
      [],
      1000,
    )
  let assert Error(decision.Unreachable("econnrefused")) =
    decision.decide(fn(_, _, _) { Error("econnrefused") }, "k", "i", [], 1000)
  let assert Error(decision.BadResponse(_)) =
    decision.decide(answering(200, "não é json"), "k", "i", [], 1000)
}

pub fn embed_reads_the_vector_test() {
  let seen = process.new_subject()
  let transport = fn(url, _headers, body) {
    process.send(seen, #(url, body))
    Ok(#(200, "{\"embedding\":{\"values\":[0.5,-1,0.25]}}"))
  }
  decision.embed(transport, "k", "trecho", decision.Query, 1000)
  |> should.equal(Ok([0.5, -1.0, 0.25]))
  let assert Ok(#(url, body)) = process.receive(seen, 1000)
  url |> should.equal(decision.embed_url)
  body
  |> string.contains("\"taskType\":\"RETRIEVAL_QUERY\"")
  |> should.be_true()
  body |> string.contains("\"outputDimensionality\":256") |> should.be_true()
}

/// The real transport, without the network: a bad URL and a closed local
/// port both come back as errors, never as a crash.
pub fn the_real_transport_reports_unreachable_test() {
  let transport = decision.hackney_transport()
  let assert Error(_) = transport("não é url", [], "{}")
  let assert Error(_) =
    transport("http://127.0.0.1:1/v1beta/decisions", [#("x", "y")], "{}")
}

pub fn summaries_and_estimates_test() {
  decision.error_summary(decision.TimedOut) |> should.equal("timed out")
  decision.error_summary(decision.HttpError(429, "x"))
  |> should.equal("HTTP 429: x")
  decision.error_summary(decision.Blocked("y"))
  |> should.equal("blocked by the safety filter: y")
  decision.error_summary(decision.Unreachable("z"))
  |> should.equal("unreachable: z")
  decision.error_summary(decision.BadResponse("w"))
  |> should.equal("unreadable answer: w")
  decision.estimate_tokens("abcd") |> should.equal(3)
}
