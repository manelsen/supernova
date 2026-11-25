//// A local stand-in for the Telegram Bot API, for tests of the live client.
////
//// It answers `getUpdates`, `sendMessage`, `editMessageText`,
//// `sendChatAction` and `leaveChat` the way Telegram does, including the 400
//// "message is not modified" for an edit that changes nothing. A test can
//// queue scripted answers per method, and every request is forwarded to the
//// test's subject.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData}

/// One request the fake received.
pub type Recorded {
  Recorded(method: String, query: String, body: String)
}

pub type Fake {
  Fake(base_url: String, state: Subject(Message))
}

pub opaque type Message {
  Queue(method: String, status: Int, body: String)
  Answer(recorded: Recorded, reply: Subject(#(Int, String)))
}

type State {
  State(
    scripts: Dict(String, List(#(Int, String))),
    texts: Dict(Int, String),
    next_id: Int,
    requests: Subject(Recorded),
  )
}

/// Start the fake; every request is sent to `requests`.
pub fn start(requests: Subject(Recorded)) -> Fake {
  let assert Ok(started) =
    actor.new(State(dict.new(), dict.new(), 100, requests))
    |> actor.on_message(handle)
    |> actor.start
  let state = started.data
  let ports = process.new_subject()
  let assert Ok(_) =
    mist.new(fn(req) { serve(state, req) })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
  let assert Ok(port) = process.receive(ports, within: 2000)
  Fake(base_url: "http://127.0.0.1:" <> int.to_string(port), state: state)
}

/// Answer the next `method` request with this status and JSON body.
pub fn queue(fake: Fake, method: String, status: Int, body: String) -> Nil {
  process.send(fake.state, Queue(method, status, body))
}

/// A `getUpdates` result with one private text message per `#(update_id,
/// text)`.
pub fn updates_body(messages: List(#(Int, String))) -> String {
  json.object([
    #("ok", json.bool(True)),
    #(
      "result",
      json.array(messages, fn(message) {
        json.object([
          #("update_id", json.int(message.0)),
          #("message", message_json(message.0, 42, message.1)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

/// A Bot API error body.
pub fn error_body(code: Int, description: String) -> String {
  json.object([
    #("ok", json.bool(False)),
    #("error_code", json.int(code)),
    #("description", json.string(description)),
  ])
  |> json.to_string
}

fn serve(
  state: Subject(Message),
  req: Request(Connection),
) -> Response(ResponseData) {
  let method = case string.split(req.path, "/") {
    ["", _bot_token, method] -> method
    _ -> req.path
  }
  let body =
    mist.read_body(req, 1_000_000)
    |> result.map(fn(r) { bit_array.to_string(r.body) |> result.unwrap("") })
    |> result.unwrap("")
  let recorded =
    Recorded(method: method, query: option.unwrap(req.query, ""), body: body)
  let #(status, answer) =
    process.call(state, 60_000, fn(reply) { Answer(recorded, reply) })
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(answer)))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Queue(method, status, body) -> {
      let queued = dict.get(state.scripts, method) |> result.unwrap([])
      actor.continue(
        State(
          ..state,
          scripts: dict.insert(
            state.scripts,
            method,
            list.append(queued, [#(status, body)]),
          ),
        ),
      )
    }
    Answer(recorded, reply) -> {
      process.send(state.requests, recorded)
      case dict.get(state.scripts, recorded.method) {
        Ok([next, ..rest]) -> {
          process.send(reply, next)
          actor.continue(
            State(
              ..state,
              scripts: dict.insert(state.scripts, recorded.method, rest),
            ),
          )
        }
        _ -> {
          let #(answer, state) = default_answer(state, recorded)
          process.send(reply, answer)
          actor.continue(state)
        }
      }
    }
  }
}

fn default_answer(
  state: State,
  recorded: Recorded,
) -> #(#(Int, String), State) {
  let sends =
    recorded.method == "sendMessage" || recorded.method == "editMessageText"
  case sends && has_long_callback_data(recorded.body) {
    True -> #(
      #(400, error_body(400, "Bad Request: BUTTON_DATA_INVALID")),
      state,
    )
    False -> answer_method(state, recorded)
  }
}

fn answer_method(state: State, recorded: Recorded) -> #(#(Int, String), State) {
  case recorded.method {
    // A file a person sent (PRD-A, A-11), in the shape of the Bot API's
    // File object, then the file itself under /file/bot<token>/.
    "getFile" -> #(
      #(
        200,
        "{\"ok\":true,\"result\":{\"file_id\":\"F1\",\"file_unique_id\":\"U1\",\"file_size\":11,\"file_path\":\"voice/file_1.oga\"}}",
      ),
      state,
    )
    "/file/bot" <> _ -> #(
      #(200, "OggS\u{0}\u{2}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}"),
      state,
    )
    "getUpdates" -> {
      // A short long poll with nothing new.
      process.sleep(50)
      #(#(200, "{\"ok\":true,\"result\":[]}"), state)
    }
    "sendMessage" -> {
      let id = state.next_id
      let text = field(recorded.body, "text") |> option.unwrap("")
      #(
        #(200, ok_message(id, chat_id(recorded.body), text)),
        State(
          ..state,
          next_id: id + 1,
          texts: dict.insert(state.texts, id, text),
        ),
      )
    }
    "editMessageText" -> {
      let id = int_field(recorded.body, "message_id") |> option.unwrap(0)
      let text = field(recorded.body, "text") |> option.unwrap("")
      case dict.get(state.texts, id) {
        Ok(current) if current == text -> #(
          #(
            400,
            error_body(
              400,
              "Bad Request: message is not modified: specified new message content and reply markup are exactly the same as a current content and reply markup of the message",
            ),
          ),
          state,
        )
        _ -> #(
          #(200, ok_message(id, chat_id(recorded.body), text)),
          State(..state, texts: dict.insert(state.texts, id, text)),
        )
      }
    }
    _ -> #(#(200, "{\"ok\":true,\"result\":true}"), state)
  }
}

fn ok_message(id: Int, chat: Int, text: String) -> String {
  json.object([
    #("ok", json.bool(True)),
    #("result", message_json(id, chat, text)),
  ])
  |> json.to_string
}

fn message_json(id: Int, chat: Int, text: String) -> json.Json {
  json.object([
    #("message_id", json.int(id)),
    #("date", json.int(1_795_000_000)),
    #("text", json.string(text)),
    #(
      "chat",
      json.object([#("id", json.int(chat)), #("type", json.string("private"))]),
    ),
    #(
      "from",
      json.object([
        #("id", json.int(chat)),
        #("is_bot", json.bool(False)),
        #("first_name", json.string("Pessoa")),
      ]),
    ),
  ])
}

fn chat_id(body: String) -> Int {
  case int_field(body, "chat_id") {
    Some(id) -> id
    None ->
      field(body, "chat_id")
      |> option.then(fn(id) { int.parse(id) |> option.from_result })
      |> option.unwrap(0)
  }
}

/// Telegram refuses a button whose `callback_data` is over 64 bytes.
fn has_long_callback_data(body: String) -> Bool {
  let decoder =
    decode.at(
      ["reply_markup", "inline_keyboard"],
      decode.list(decode.list(decode.at(["callback_data"], decode.string))),
    )
  case json.parse(body, decoder) {
    Ok(rows) ->
      list.any(list.flatten(rows), fn(data) { string.byte_size(data) > 64 })
    Error(_) -> False
  }
}

fn field(body: String, name: String) -> Option(String) {
  json.parse(body, decode.at([name], decode.string)) |> option.from_result
}

fn int_field(body: String, name: String) -> Option(Int) {
  json.parse(body, decode.at([name], decode.int)) |> option.from_result
}
