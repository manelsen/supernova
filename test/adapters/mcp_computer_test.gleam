//// PRD-S, S-04: Supernova speaks MCP with the servers inside the computer
//// through `POST /v1/mcp`. The computer is a fake HTTP service here.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import supernova/adapters/mcp/computer

type Fake

@external(erlang, "mcp_computer_fake_ffi", "start")
fn start_fake(responder: fn(String) -> #(Int, String)) -> Fake

@external(erlang, "mcp_computer_fake_ffi", "requests")
fn requests(fake: Fake) -> List(String)

@external(erlang, "mcp_computer_fake_ffi", "stop")
fn stop(fake: Fake) -> Nil

@external(erlang, "erlang", "element")
fn port_of(index: Int, fake: Fake) -> Int

fn computer_at(fake: Fake) -> computer.Computer {
  computer.Computer(
    url: "http://127.0.0.1:" <> int.to_string(port_of(1, fake)),
    token: "token-do-computador",
    timeout_ms: 5000,
  )
}

const hash_ana = "5d407def0bd4d7b8"

/// A computer whose MCP server is well behaved.
fn good_computer(body: String) -> #(Int, String) {
  let action = json.parse(body, decode.at(["acao"], decode.string))
  let method =
    json.parse(body, decode.at(["mensagem", "method"], decode.string))
  let id = json.parse(body, decode.at(["mensagem", "id"], decode.int))
  case action, method, id {
    Ok("abrir"), _, _ -> #(200, "{\"ok\":true}")
    Ok("fechar"), _, _ -> #(200, "{\"ok\":true,\"fechada\":true}")
    _, _, _ if body == "{\"pessoa\":\"" <> hash_ana <> "\"}" -> #(
      200,
      "{\"ok\":true,\"apagado\":true}",
    )
    Ok("chamar"), Ok("initialize"), Ok(id) ->
      answer(id, "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{}}")
    Ok("chamar"), Ok("notifications/initialized"), _ -> #(200, "{\"ok\":true}")
    Ok("chamar"), Ok("tools/list"), Ok(id) ->
      answer(
        id,
        "{\"tools\":[{\"name\":\"browser_fill_form\",\"description\":\"Fill\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"fields\":{\"type\":\"array\"}}}}]}",
      )
    Ok("chamar"), Ok("tools/call"), Ok(id) ->
      case string.contains(body, "\"quebra\"") {
        True ->
          answer(
            id,
            "{\"content\":[{\"type\":\"text\",\"text\":\"falhou\"}],\"isError\":true}",
          )
        False ->
          answer(
            id,
            "{\"content\":[{\"type\":\"text\",\"text\":\"preenchido\"}]}",
          )
      }
    _, _, _ -> #(400, "{\"ok\":false,\"error\":\"bad request\"}")
  }
}

fn answer(id: Int, result: String) -> #(Int, String) {
  #(
    200,
    "{\"ok\":true,\"resposta\":{\"jsonrpc\":\"2.0\",\"id\":"
      <> int.to_string(id)
      <> ",\"result\":"
      <> result
      <> "}}",
  )
}

pub fn open_list_call_close_test() {
  let fake = start_fake(good_computer)
  let pc = computer_at(fake)
  let assert Ok(session) =
    computer.open(pc, "s-1", computer.Playwright, "telegram:42", 3)
  let assert Ok([tool]) = computer.tools(session)
  tool.name |> should.equal("browser_fill_form")
  let assert Some(schema) = tool.schema
  string.contains(schema, "\"fields\"") |> should.be_true
  computer.call(session, "browser_fill_form", "{\"fields\":[]}")
  |> should.equal(Ok("preenchido"))
  computer.call(session, "browser_fill_form", "{\"x\":\"quebra\"}")
  |> should.equal(Error("falhou"))
  computer.call(session, "browser_fill_form", "nada") |> should.be_error
  computer.close(session)

  let sent = requests(fake)
  // The token goes in the header, the person as a hash, nothing else.
  list.all(sent, fn(raw) {
    string.contains(raw, "authorization: Bearer token-do-computador")
  })
  |> should.be_true
  list.any(sent, fn(raw) { string.contains(raw, "telegram:42") })
  |> should.be_false
  list.any(sent, fn(raw) {
    string.contains(raw, "\"pessoa\":\"" <> computer.person_hash("telegram:42"))
  })
  |> should.be_true
  list.any(sent, fn(raw) { string.contains(raw, "\"acao\":\"fechar\"") })
  |> should.be_true
  // Every call goes to the person's computer, at the dispatcher.
  list.all(sent, fn(raw) {
    string.starts_with(
      raw,
      "POST /v1/pessoas/" <> computer.person_hash("telegram:42") <> "/mcp ",
    )
  })
  |> should.be_true
  stop(fake)
}

/// Nothing secret of Supernova goes to the computer.
pub fn no_secret_leaves_supernova_test() {
  let fake = start_fake(good_computer)
  let assert Ok(session) =
    computer.open(computer_at(fake), "s-2", computer.Filesystem, "sim:ana", 1)
  let _ = computer.tools(session)
  computer.close(session)
  let assert Ok(Nil) = computer.forget_person(computer_at(fake), "sim:ana")
  let sent = string.join(requests(fake), "\n")
  list.each(
    ["API_KEY", "api_key", "sk-", "SUPERNOVA_", "TAVILY", "bot_token"],
    fn(secret) { string.contains(sent, secret) |> should.be_false },
  )
  stop(fake)
}

pub fn person_hash_test() {
  let hash = computer.person_hash("telegram:42")
  string.length(hash) |> should.equal(16)
  hash |> should.equal(string.lowercase(hash))
  computer.person_hash("telegram:43") |> should.not_equal(hash)
}

/// A server that speaks an unknown version, or a broken computer, is an
/// error, and the session is closed.
pub fn failures_are_errors_test() {
  let fake =
    start_fake(fn(body) {
      case string.contains(body, "\"initialize\"") {
        True -> answer(1, "{\"protocolVersion\":\"1999-01-01\"}")
        False -> #(200, "{\"ok\":true}")
      }
    })
  computer.open(computer_at(fake), "s-3", computer.Playwright, "sim:ana", 1)
  |> should.be_error
  requests(fake)
  |> list.any(fn(raw) { string.contains(raw, "\"acao\":\"fechar\"") })
  |> should.be_true
  stop(fake)

  let broken = start_fake(fn(_) { #(500, "oops") })
  computer.open(computer_at(broken), "s-4", computer.Playwright, "sim:ana", 1)
  |> should.be_error
  stop(broken)

  let refused =
    start_fake(fn(_) {
      #(400, "{\"ok\":false,\"error\":\"too many open sessions\"}")
    })
  let assert Error(reason) =
    computer.open(
      computer_at(refused),
      "s-5",
      computer.Playwright,
      "sim:ana",
      1,
    )
  string.contains(reason, "too many open sessions") |> should.be_true
  stop(refused)

  computer.open(
    computer.Computer(url: "http://127.0.0.1:1", token: "", timeout_ms: 500),
    "s-6",
    computer.Playwright,
    "sim:ana",
    1,
  )
  |> should.be_error
}
