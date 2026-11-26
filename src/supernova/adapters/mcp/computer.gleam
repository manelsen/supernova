//// The MCP servers inside the computer, reached through its authenticated
//// door (`POST /v1/mcp`, PRD-S, S-04). The servers and their arguments are
//// chosen by the computer's service; Supernova names a server, a person
//// and a probe, and then speaks MCP through the session.
////
//// Nothing secret goes in a request: the person is a hash of the agent id,
//// and the only credential is the computer's own token, in the header.

import envoy
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/adapters/mcp/protocol
import supernova/llm/provider

/// Where the computer is, and its token.
pub type Computer {
  Computer(url: String, token: String, timeout_ms: Int)
}

/// An open MCP session in the computer.
pub type Session {
  Session(computer: Computer, id: String)
}

pub type Server {
  Playwright
  Filesystem
}

/// The computer of this instance, when one is configured.
pub fn from_env() -> Option(Computer) {
  let read = fn(name) {
    envoy.get(name) |> result.map(string.trim) |> result.unwrap("")
  }
  case read("SUPERNOVA_COMPUTER_URL") {
    "" -> None
    url ->
      Some(Computer(
        url: url,
        token: read("SUPERNOVA_COMPUTER_TOKEN"),
        timeout_ms: 150_000,
      ))
  }
}

/// The person's folder name in the computer.
pub fn person_hash(agent_id: String) -> String {
  ffi_person_hash(agent_id)
}

fn server_name(server: Server) -> String {
  case server {
    Playwright -> "playwright"
    Filesystem -> "filesystem"
  }
}

/// Open a session of `server` for the person's probe, and greet the server
/// (initialize, then notifications/initialized).
pub fn open(
  computer: Computer,
  session_id: String,
  server: Server,
  agent_id: String,
  probe: Int,
) -> Result(Session, String) {
  use _ <- result.try(post(
    computer,
    json.object([
      #("acao", json.string("abrir")),
      #("sessao", json.string(session_id)),
      #("servidor", json.string(server_name(server))),
      #("pessoa", json.string(person_hash(agent_id))),
      #("sonda", json.int(probe)),
    ]),
  ))
  let session = Session(computer: computer, id: session_id)
  let greeted = {
    use answer <- result.try(request(
      session,
      "initialize",
      protocol.initialize_params(),
    ))
    use _ <- result.try(protocol.check_initialize(answer))
    notify(session, "notifications/initialized")
  }
  case greeted {
    Ok(Nil) -> Ok(session)
    Error(reason) -> {
      close(session)
      Error(reason)
    }
  }
}

/// The server's tools, with their own names and full schemas.
pub fn tools(
  session: Session,
) -> Result(List(provider.ToolDefinition), String) {
  use answer <- result.try(request(session, "tools/list", json.object([])))
  protocol.tools(answer, fn(name) { name })
}

/// Call one tool; its text, or the error it gave.
pub fn call(
  session: Session,
  tool: String,
  arguments_json: String,
) -> Result(String, String) {
  use arguments <- result.try(
    json.parse(arguments_json, decode.dynamic)
    |> result.replace_error("arguments are not JSON"),
  )
  use answer <- result.try(request(
    session,
    "tools/call",
    json.object([
      #("name", json.string(tool)),
      #("arguments", provider.dynamic_json(arguments)),
    ]),
  ))
  protocol.call_text(answer)
}

pub fn close(session: Session) -> Nil {
  let _ =
    post(
      session.computer,
      json.object([
        #("acao", json.string("fechar")),
        #("sessao", json.string(session.id)),
      ]),
    )
  Nil
}

/// /esquecer: close the person's sessions and delete their folder.
pub fn forget_person(
  computer: Computer,
  agent_id: String,
) -> Result(Nil, String) {
  post(
    computer,
    json.object([
      #("acao", json.string("apagar_pessoa")),
      #("pessoa", json.string(person_hash(agent_id))),
    ]),
  )
  |> result.replace(Nil)
}

/// One JSON-RPC request through the session; the `result` as JSON text.
fn request(
  session: Session,
  method: String,
  params: json.Json,
) -> Result(String, String) {
  let id = ffi_unique_id()
  use answer <- result.try(post(
    session.computer,
    json.object([
      #("acao", json.string("chamar")),
      #("sessao", json.string(session.id)),
      #(
        "mensagem",
        json.parse(protocol.request(id, method, params), decode.dynamic)
          |> result.map(provider.dynamic_json)
          |> result.unwrap(json.null()),
      ),
    ]),
  ))
  case json.parse(answer, decode.at(["resposta"], decode.dynamic)) {
    Ok(value) ->
      protocol.result_of(json.to_string(provider.dynamic_json(value)))
    Error(_) -> Error("the computer gave no answer to " <> method)
  }
}

fn notify(session: Session, method: String) -> Result(Nil, String) {
  post(
    session.computer,
    json.object([
      #("acao", json.string("chamar")),
      #("sessao", json.string(session.id)),
      #(
        "mensagem",
        json.object([
          #("jsonrpc", json.string("2.0")),
          #("method", json.string(method)),
        ]),
      ),
    ]),
  )
  |> result.replace(Nil)
}

/// POST to /v1/mcp. The service answers {"ok": true, ...} or
/// {"ok": false, "error": "..."}; anything else is a broken computer.
fn post(computer: Computer, body: json.Json) -> Result(String, String) {
  case
    ffi_run(
      endpoint(computer.url),
      computer.token,
      json.to_string(body),
      computer.timeout_ms,
    )
  {
    Error(reason) ->
      Error("computador unreachable: " <> string.slice(reason, 0, 200))
    Ok(#(status, text, _image)) -> {
      let answer = {
        use ok <- decode.field("ok", decode.bool)
        use error <- decode.optional_field("error", "", decode.string)
        decode.success(#(ok, error))
      }
      case status, json.parse(text, answer) {
        200, Ok(#(True, _)) -> Ok(text)
        _, Ok(#(False, error)) -> Error("computador: " <> error)
        _, _ ->
          Error(
            "computador answered "
            <> int.to_string(status)
            <> ": "
            <> string.slice(text, 0, 200),
          )
      }
    }
  }
}

fn endpoint(base: String) -> String {
  case string.ends_with(base, "/") {
    True -> base <> "v1/mcp"
    False -> base <> "/v1/mcp"
  }
}

@external(erlang, "supernova_computer_ffi", "run")
fn ffi_run(
  url: String,
  token: String,
  body: String,
  timeout_ms: Int,
) -> Result(#(Int, String, String), String)

@external(erlang, "supernova_mcp_computer_ffi", "person_hash")
fn ffi_person_hash(agent_id: String) -> String

@external(erlang, "supernova_mcp_computer_ffi", "unique_id")
fn ffi_unique_id() -> Int
