//// A local stand-in for the Gemini API that serves what the real API
//// answered (`test/fixtures/gemini`, recorded by `dev/gemini/gravar.py`,
//// anonymized). It checks what the real API checks: the key header, the
//// upload offsets and the part size it announces. Every request goes to
//// the test's subject.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import mist

pub type Recorded {
  Recorded(
    method: String,
    path: String,
    key: String,
    command: String,
    offset: String,
    size: Int,
    body: BitArray,
  )
}

type Fixture {
  Fixture(status: Int, headers: Dict(String, String), body: String)
}

const google = "https://generativelanguage.googleapis.com"

fn fixture(name: String) -> Fixture {
  let assert Ok(text) = read("test/fixtures/gemini/" <> name <> ".json")
  let decoder = {
    use status <- decode.subfield(["response", "status"], decode.int)
    use headers <- decode.subfield(
      ["response", "headers"],
      decode.dict(decode.string, decode.string),
    )
    use body <- decode.subfield(["response", "body"], decode.string)
    decode.success(Fixture(status, headers, body))
  }
  let assert Ok(loaded) = json.parse(text, decoder)
  loaded
}

/// The uploaded size the fake reports, from the recorded upload.
pub fn granularity() -> Int {
  let assert Ok(text) =
    dict.get(fixture("upload_start").headers, "x-goog-upload-chunk-granularity")
  let assert Ok(n) = int.parse(text)
  n
}

type State {
  State(deleted: Bool, next_offset: Int)
}

type Msg {
  Delete
  Advance(Int)
  Look(process.Subject(State))
}

/// Start the fake; returns its base URL.
pub fn start(requests: Subject(Recorded)) -> String {
  let assert Ok(state) =
    actor.new(State(False, 0))
    |> actor.on_message(fn(state, msg) {
      case msg {
        Delete -> actor.continue(State(..state, deleted: True))
        Advance(n) -> actor.continue(State(..state, next_offset: n))
        Look(reply) -> {
          process.send(reply, state)
          actor.continue(state)
        }
      }
    })
    |> actor.start
  let state = state.data
  let ports = process.new_subject()
  let assert Ok(_) =
    mist.new(fn(req: request.Request(mist.Connection)) {
      let body =
        mist.read_body(req, 100_000_000)
        |> result.map(fn(r) { r.body })
        |> result.unwrap(<<>>)
      let header = fn(name) {
        request.get_header(req, name) |> result.unwrap("")
      }
      let method = string.uppercase(string.inspect(req.method))
      let base = "http://" <> header("host")
      process.send(
        requests,
        Recorded(
          method:,
          path: req.path,
          key: header("x-goog-api-key"),
          command: header("x-goog-upload-command"),
          offset: header("x-goog-upload-offset"),
          size: bit_array.byte_size(body),
          body:,
        ),
      )
      let serve = fn(name) {
        let f = fixture(name)
        f.headers
        |> dict.to_list
        |> list.fold(response.new(f.status), fn(resp, pair) {
          response.set_header(
            resp,
            pair.0,
            string.replace(pair.1, google, base),
          )
        })
        |> response.set_body(
          mist.Bytes(
            bytes_tree.from_string(string.replace(f.body, google, base)),
          ),
        )
      }
      let text = bit_array.to_string(body) |> result.unwrap("")
      case header("x-goog-api-key"), req.path, header("x-goog-upload-command") {
        "", _, _ -> serve("read_error")
        _, "/upload/v1beta/files", "start" -> serve("upload_start")
        _, "/upload/v1beta/files", command -> {
          let look = process.call(state, 1000, Look)
          let offset =
            int.parse(header("x-goog-upload-offset")) |> result.unwrap(-1)
          let size = bit_array.byte_size(body)
          let finalize = command == "upload, finalize"
          case
            offset == look.next_offset,
            finalize || size % granularity() == 0
          {
            True, True -> {
              process.send(state, Advance(offset + size))
              case finalize {
                True -> serve("upload_part_2")
                False -> serve("upload_part_1")
              }
            }
            _, _ -> serve("upload_bad_granularity")
          }
        }
        _, "/v1beta/files/fixture", _ ->
          case method, process.call(state, 1000, Look).deleted {
            "DELETE", _ -> {
              process.send(state, Delete)
              serve("file_delete")
            }
            _, True -> serve("file_gone")
            _, False -> serve("file_active")
          }
        _, path, _ ->
          case string.ends_with(path, ":generateContent") {
            False ->
              response.new(404)
              |> response.set_body(mist.Bytes(bytes_tree.new()))
            True ->
              case
                string.contains(text, "audio/nao-existe"),
                string.contains(text, "\"file_data\""),
                string.contains(text, "responseModalities")
              {
                True, _, _ -> serve("read_error")
                _, True, _ -> serve("read_file")
                _, _, True -> serve("tts")
                _, _, _ -> serve("read_inline")
              }
          }
      }
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
  let assert Ok(port) = process.receive(ports, within: 2000)
  "http://127.0.0.1:" <> int.to_string(port)
}

@external(erlang, "supernova_gemini_fake_ffi", "read")
fn read(path: String) -> Result(String, Nil)

pub fn text(bytes: BitArray) -> String {
  bit_array.to_string(bytes) |> result.unwrap("")
}
