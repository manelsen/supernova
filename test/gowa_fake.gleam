//// A local stand-in for the GOWA REST API: every request is forwarded to
//// the test's subject with its path, authorization and body, and answered
//// 200.

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/result
import mist

/// The bytes of the image the fake serves.
pub const png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 7, 7, 7>>

pub type Recorded {
  Recorded(path: String, authorization: String, device: String, body: String)
}

/// Start the fake; returns its base URL.
pub fn start(requests: Subject(Recorded)) -> String {
  let ports = process.new_subject()
  let assert Ok(_) =
    mist.new(fn(req: request.Request(mist.Connection)) {
      let body =
        mist.read_body(req, 1_000_000)
        |> result.map(fn(r) { bit_array.to_string(r.body) |> result.unwrap("") })
        |> result.unwrap("")
      process.send(
        requests,
        Recorded(
          path: req.path,
          authorization: request.get_header(req, "authorization")
            |> result.unwrap(""),
          device: request.get_header(req, "x-device-id") |> result.unwrap(""),
          body: body,
        ),
      )
      case req.path {
        // A downloaded image, as GOWA serves its media.
        "/statics/media/foto.png" ->
          response.new(200)
          |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(png)))
        _ ->
          response.new(200)
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string("{\"code\":\"SUCCESS\"}")),
          )
      }
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
  let assert Ok(port) = process.receive(ports, within: 2000)
  "http://127.0.0.1:" <> int.to_string(port)
}
