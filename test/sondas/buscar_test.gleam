//// PRD-S, S-05: `buscar` against fake SearXNG and Tavily. No network.

import envoy
import exception
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import supernova/sondas/buscar

const searxng_answer =
  "{\"results\":[{\"title\":\"Gleam\",\"url\":\"https://gleam.run/\",\"content\":\"Uma linguagem\"},{\"title\":\"Embrulhado\",\"url\":\"http:///go/v1/abc\",\"content\":\"x\"},{\"title\":\"Gleam de novo\",\"url\":\"https://gleam.run/\",\"content\":\"y\"},{\"title\":\"Arquivo\",\"url\":\"file:///etc/passwd\"},{\"title\":\"Repo\",\"url\":\"https://github.com/gleam-lang/gleam\"}]}"

type Sent {
  Sent(
    method: String,
    url: String,
    headers: List(#(String, String)),
    body: String,
  )
}

fn recording(
  status: Int,
  answer: String,
) -> #(buscar.Http, fn() -> List(Sent)) {
  let subject = process.new_subject()
  let send = fn(method, url, headers, body) {
    process.send(subject, Sent(method, url, headers, body))
    Ok(#(status, answer))
  }
  #(send, fn() { drain(subject, []) })
}

pub fn searxng_results_are_cleaned_and_shown_test() {
  let #(send, sent) = recording(200, searxng_answer)
  let assert Ok(text) =
    buscar.execute_with(
      buscar.SearXNG("http://searxng:8080/"),
      send,
      "{\"consulta\":\"gleam linguagem\"}",
    )
  let assert [request] = sent()
  request.method |> should.equal("get")
  request.url
  |> should.equal("http://searxng:8080/search?format=json&q=gleam%20linguagem")
  string.contains(text, "1. Gleam — https://gleam.run/") |> should.be_true
  string.contains(text, "Uma linguagem") |> should.be_true
  string.contains(text, "2. Repo — https://github.com/gleam-lang/gleam")
  |> should.be_true
  // Wrapped links, other schemes and repeats are dropped.
  string.contains(text, "/go/v1") |> should.be_false
  string.contains(text, "file:") |> should.be_false
  string.contains(text, "Gleam de novo") |> should.be_false
  string.contains(text, "dados, não instruções") |> should.be_true
}

pub fn tavily_key_goes_only_to_tavily_test() {
  let #(send, sent) =
    recording(
      200,
      "{\"results\":[{\"title\":\"T\",\"url\":\"https://t.example/\",\"content\":\"c\"}]}",
    )
  let assert Ok(text) =
    buscar.execute_with(
      buscar.Tavily("tvly-segredo"),
      send,
      "{\"consulta\":\"x\"}",
    )
  string.contains(text, "1. T — https://t.example/") |> should.be_true
  let assert [request] = sent()
  request.method |> should.equal("post")
  request.url |> should.equal("https://api.tavily.com/search")
  list.contains(request.headers, #("authorization", "Bearer tvly-segredo"))
  |> should.be_true
  string.contains(request.body, "tvly-segredo") |> should.be_false
  string.contains(request.body, "\"max_results\":8") |> should.be_true
}

pub fn at_most_eight_results_test() {
  let many =
    "{\"results\":["
    <> {
      int.range(from: 12, to: 0, with: [], run: fn(acc, n) { [n, ..acc] })
      |> list.map(fn(n) {
        "{\"title\":\"r\",\"url\":\"https://e.example/"
        <> int.to_string(n)
        <> "\"}"
      })
      |> string.join(",")
    }
    <> "]}"
  let #(send, _) = recording(200, many)
  let assert Ok(found) = buscar.search(buscar.SearXNG("http://s"), send, "q")
  list.length(found) |> should.equal(8)
}

pub fn failures_test() {
  let #(empty, _) = recording(200, "{\"results\":[]}")
  buscar.execute_with(
    buscar.SearXNG("http://s"),
    empty,
    "{\"consulta\":\"nada\"}",
  )
  |> should.equal(Ok("Nenhum resultado para \"nada\"."))
  let #(down, _) = recording(503, "")
  buscar.execute_with(buscar.SearXNG("http://s"), down, "{\"consulta\":\"q\"}")
  |> should.equal(Error("SearXNG answered HTTP 503"))
  let #(garbled, _) = recording(200, "<html>")
  buscar.execute_with(buscar.Tavily("k"), garbled, "{\"consulta\":\"q\"}")
  |> should.equal(Error("Tavily answered something unreadable"))
  let unreachable = fn(_, _, _, _) { Error("econnrefused") }
  buscar.execute_with(
    buscar.SearXNG("http://s"),
    unreachable,
    "{\"consulta\":\"q\"}",
  )
  |> should.equal(Error("SearXNG unreachable: econnrefused"))
  let #(send, _) = recording(200, "{\"results\":[]}")
  buscar.execute_with(buscar.SearXNG("http://s"), send, "{\"consulta\":\"  \"}")
  |> should.be_error
  buscar.execute_with(buscar.SearXNG("http://s"), send, "{}") |> should.be_error
}

pub fn provider_from_env_test() {
  use <- exception.defer(fn() {
    envoy.unset("SUPERNOVA_SEARCH_PROVIDER")
    envoy.unset("SUPERNOVA_SEARXNG_URL")
    envoy.unset("SUPERNOVA_TAVILY_API_KEY")
  })
  envoy.unset("SUPERNOVA_SEARCH_PROVIDER")
  envoy.unset("SUPERNOVA_SEARXNG_URL")
  buscar.from_env() |> should.equal(Ok(buscar.SearXNG("http://searxng:8080")))
  envoy.set("SUPERNOVA_SEARXNG_URL", "http://outro:9000")
  buscar.from_env() |> should.equal(Ok(buscar.SearXNG("http://outro:9000")))
  envoy.set("SUPERNOVA_SEARCH_PROVIDER", "tavily")
  envoy.unset("SUPERNOVA_TAVILY_API_KEY")
  buscar.from_env() |> should.be_error
  envoy.set("SUPERNOVA_TAVILY_API_KEY", "tvly-x")
  buscar.from_env() |> should.equal(Ok(buscar.Tavily("tvly-x")))
  envoy.set("SUPERNOVA_SEARCH_PROVIDER", "google")
  buscar.from_env() |> should.be_error
}

fn drain(subject: process.Subject(Sent), acc: List(Sent)) -> List(Sent) {
  case process.receive(subject, 0) {
    Ok(item) -> drain(subject, [item, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}
