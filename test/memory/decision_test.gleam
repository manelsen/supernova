//// The decision client speaks to Perplexity's Decider and to Gemini
//// Decision, with its own timeout, telling a safety block from other
//// errors; embeddings come back in order, batched for Perplexity.

import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import supernova/memory/decision

fn answering(status: Int, body: String) -> decision.Transport {
  fn(_url, _headers, _body) { Ok(#(status, body)) }
}

fn pplx() -> decision.Endpoint {
  decision.endpoint(decision.Perplexity, "segredo")
}

fn gemini() -> decision.Endpoint {
  decision.endpoint(decision.Gemini, "segredo")
}

pub fn perplexity_is_the_default_shape_test() {
  let seen = process.new_subject()
  let transport = fn(url, headers, body) {
    process.send(seen, #(url, headers, body))
    Ok(#(
      200,
      "{\"model\":\"pplx-decider-v1.3\",\"answers\":{\"falado\":{\"type\":\"noul\",\"noul\":0.93},\"tipo\":{\"type\":\"choice\",\"choice\":\"lembranca\",\"probabilities\":{\"lembranca\":0.7,\"conversa\":0.3}}},\"usage\":{\"input_tokens\":270,\"output_tokens\":4}}",
    ))
  }
  let assert Ok(answers) =
    decision.decide(
      transport,
      pplx(),
      "a conversa",
      [
        decision.YesNo("falado", "Já?"),
        decision.Choice("tipo", "O que é?", [
          #("lembranca", "Lembrança"),
          #("conversa", "Conversa"),
        ]),
      ],
      1000,
    )
  dict.get(answers.yes, "falado") |> should.equal(Ok(0.93))
  let assert Ok(kinds) = dict.get(answers.choices, "tipo")
  dict.get(kinds, "lembranca") |> should.equal(Ok(0.7))
  answers.input_tokens |> should.equal(270)
  let assert Ok(#(url, headers, body)) = process.receive(seen, 1000)
  url |> should.equal("https://api.perplexity.ai/v1/decisions")
  headers
  |> should.equal([
    #("content-type", "application/json"),
    #("authorization", "Bearer segredo"),
  ])
  body |> string.contains("\"model\":\"pplx-decider-v1.3\"") |> should.be_true()
  body |> string.contains("\"state\":\"a conversa\"") |> should.be_true()
  body
  |> string.contains(
    "\"tipo\":{\"type\":\"choice\",\"instructions\":\"O que é?\",\"criteria\":{\"lembranca\":\"Lembrança\",\"conversa\":\"Conversa\"}}",
  )
  |> should.be_true()
}

pub fn gemini_keeps_its_own_shape_test() {
  let seen = process.new_subject()
  let transport = fn(url, headers, body) {
    process.send(seen, #(url, headers, body))
    Ok(#(
      200,
      "{\"answers\":{\"t1\":{\"type\":\"noul\",\"noul\":1}},\"usage\":{\"total_input_tokens\":6157}}",
    ))
  }
  let assert Ok(answers) =
    decision.decide(transport, gemini(), "i", [decision.YesNo("t1", "q")], 1000)
  // JSON may write a probability as an integer.
  dict.get(answers.yes, "t1") |> should.equal(Ok(1.0))
  answers.input_tokens |> should.equal(6157)
  let assert Ok(#(url, headers, body)) = process.receive(seen, 1000)
  url |> should.equal(decision.decisions_url(decision.Gemini))
  list.contains(headers, #("x-goog-api-key", "segredo")) |> should.be_true()
  body |> string.contains("\"input\":\"i\"") |> should.be_true()
  body |> string.contains("\"model\":\"gemini-decision-1\"") |> should.be_true()
}

/// A transport that never answers: the call gives up at the timeout.
pub fn decide_times_out_test() {
  let never = fn(_url, _headers, _body) {
    let nothing = process.new_subject()
    let _ = process.receive(nothing, 60_000)
    Ok(#(200, "{}"))
  }
  decision.decide(never, pplx(), "i", [], 50)
  |> should.equal(Error(decision.TimedOut))
}

pub fn decide_tells_a_safety_block_from_other_errors_test() {
  let blocked =
    "{\"error\":{\"message\":\"Input blocked: The prompt could not be submitted. The prompt contains sensitive words\",\"code\":\"invalid_request\"}}"
  let assert Error(decision.Blocked(_)) =
    decision.decide(answering(400, blocked), gemini(), "i", [], 1000)
  let assert Error(decision.Blocked(_)) =
    decision.decide(
      answering(400, "{\"error\":{\"code\":\"safety\"}}"),
      gemini(),
      "i",
      [],
      1000,
    )
  let assert Error(decision.HttpError(429, _)) =
    decision.decide(answering(429, "{\"error\":{}}"), pplx(), "i", [], 1000)
  let assert Error(decision.HttpError(400, _)) =
    decision.decide(
      answering(400, "{\"error\":{\"message\":\"too many tokens\"}}"),
      pplx(),
      "i",
      [],
      1000,
    )
  let assert Error(decision.Unreachable("econnrefused")) =
    decision.decide(
      fn(_, _, _) { Error("econnrefused") },
      pplx(),
      "i",
      [],
      1000,
    )
  let assert Error(decision.BadResponse(_)) =
    decision.decide(answering(200, "não é json"), pplx(), "i", [], 1000)
}

fn b64(bytes: BitArray) -> String {
  bit_array.base64_encode(bytes, True)
}

/// Perplexity: int8 vectors in base64, many texts per request, in order
/// whatever order the response lists them.
pub fn perplexity_embeddings_come_in_batches_test() {
  let seen = process.new_subject()
  let transport = fn(url, _headers, body) {
    process.send(seen, #(url, body))
    Ok(#(
      200,
      "{\"data\":[{\"index\":1,\"embedding\":\""
        <> b64(<<255, 2>>)
        <> "\"},{\"index\":0,\"embedding\":\""
        <> b64(<<127, 128>>)
        <> "\"}],\"usage\":{\"total_tokens\":14}}",
    ))
  }
  let assert Ok(#(vectors, tokens)) =
    decision.embed_many(transport, pplx(), ["a", "b"], decision.Document, 1000)
  vectors |> should.equal([[127.0, -128.0], [-1.0, 2.0]])
  tokens |> should.equal(14)
  let assert Ok(#(url, body)) = process.receive(seen, 1000)
  url |> should.equal("https://api.perplexity.ai/v1/embeddings")
  body
  |> string.contains("\"model\":\"pplx-embed-v2-context-0.6b\"")
  |> should.be_true()
  body |> string.contains("\"input\":[\"a\",\"b\"]") |> should.be_true()
  body |> string.contains("\"input_type\":\"document\"") |> should.be_true()
}

pub fn perplexity_splits_long_lists_into_batches_test() {
  let calls = process.new_subject()
  let one = b64(<<1>>)
  let transport = fn(_url, _headers, body) {
    process.send(calls, body)
    let n = list.length(string.split(body, "\"t")) - 1
    let data =
      int.range(0, n, [], list.prepend)
      |> list.reverse
      |> list.map(fn(i) {
        "{\"index\":"
        <> string.inspect(i)
        <> ",\"embedding\":\""
        <> one
        <> "\"}"
      })
      |> string.join(",")
    Ok(#(200, "{\"data\":[" <> data <> "],\"usage\":{\"total_tokens\":1}}"))
  }
  let texts = list.repeat("tx", decision.embed_batch + 3)
  let assert Ok(#(vectors, tokens)) =
    decision.embed_many(transport, pplx(), texts, decision.Document, 1000)
  list.length(vectors) |> should.equal(decision.embed_batch + 3)
  tokens |> should.equal(2)
  let assert Ok(_) = process.receive(calls, 1000)
  let assert Ok(_) = process.receive(calls, 1000)
}

pub fn gemini_embeds_one_text_per_request_test() {
  let seen = process.new_subject()
  let transport = fn(url, _headers, body) {
    process.send(seen, #(url, body))
    Ok(#(200, "{\"embedding\":{\"values\":[0.5,-1,0.25]}}"))
  }
  decision.embed(transport, gemini(), "trecho", decision.Query, 1000)
  |> should.equal(Ok([0.5, -1.0, 0.25]))
  let assert Ok(#(url, body)) = process.receive(seen, 1000)
  url |> should.equal(decision.embed_url(decision.Gemini))
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
    transport("http://127.0.0.1:1/v1/decisions", [#("x", "y")], "{}")
}

pub fn names_prices_summaries_and_estimates_test() {
  decision.provider_name(decision.Perplexity) |> should.equal("perplexity")
  decision.provider_name(decision.Gemini) |> should.equal("gemini")
  decision.decision_usd_per_million(decision.Perplexity) |> should.equal(0.02)
  decision.embed_usd_per_million(decision.Gemini) |> should.equal(0.2)
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
  decision.int8_vector("não é base64") |> should.equal(Error(Nil))
}
