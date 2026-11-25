//// Gemini as a reader of media (PRD-A, A-03): one call that turns an
//// audio, a video or a document into text, with a prompt as system
//// instruction. Ported from Amélie's Gemini adapter, adjusted:
////
//// - up to 20 MB the medium goes inline, in one call; above, through the
////   Files API (uploaded in parts, read from disk piece by piece), waited
////   for with growing pauses, used, and deleted;
//// - the file state is read from the JSON, not searched as text;
//// - errors keep the API's own message (never the response body of a
////   success, which may carry the person's words);
//// - the token usage comes back, to be charged to the person.
////
//// The API key goes in a header and only to the configured base: file URIs
//// come from responses, and the key must not follow them elsewhere.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/result
import gleam/string

pub const google = "https://generativelanguage.googleapis.com"

/// Largest medium sent inline (the documented limit of a request).
pub const inline_limit = 20_000_000

pub type Client {
  Client(api_key: String, base: String)
}

pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int)
}

pub type Reply {
  Reply(text: String, usage: Usage)
}

type Method {
  Get
  Post
  Delete
}

@external(erlang, "supernova_gemini_ffi", "request")
fn http(
  method: Method,
  url: String,
  api_key: String,
  content_type: String,
  body: BitArray,
) -> Result(#(Int, BitArray), String)

@external(erlang, "supernova_gemini_ffi", "upload_resumable")
fn upload(
  start_url: String,
  api_key: String,
  path: String,
  mime: String,
  size: Int,
) -> Result(BitArray, String)

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, decode.Dynamic)

/// Read a medium on disk into text, following `instruction`.
pub fn read(
  client: Client,
  model: String,
  instruction: String,
  path: String,
  mime: String,
  size: Int,
) -> Result(Reply, String) {
  let mime = base_mime(mime)
  case size <= inline_limit {
    True -> {
      use bytes <- result.try(
        read_file(path) |> result.replace_error("could not read the medium"),
      )
      generate(client, model, instruction, inline_part(mime, bytes))
    }
    False -> {
      use file <- result.try(upload_file(client, path, mime, size))
      let reply = {
        use _ <- result.try(wait_active(client, file.name, waits))
        generate(client, model, instruction, file_part(mime, file.uri))
      }
      // Always deleted, whatever happened: the Files API keeps it 48 h.
      let _ = delete_file(client, file.name)
      reply
    }
  }
}

fn base_mime(mime: String) -> String {
  case string.split_once(mime, ";") {
    Ok(#(base, _)) -> string.trim(base)
    Error(Nil) -> string.trim(mime)
  }
}

fn inline_part(mime: String, bytes: BitArray) -> json.Json {
  json.object([
    #(
      "inline_data",
      json.object([
        #("mime_type", json.string(mime)),
        #("data", json.string(bit_array.base64_encode(bytes, True))),
      ]),
    ),
  ])
}

fn file_part(mime: String, uri: String) -> json.Json {
  json.object([
    #(
      "file_data",
      json.object([
        #("mime_type", json.string(mime)),
        #("file_uri", json.string(uri)),
      ]),
    ),
  ])
}

fn generate(
  client: Client,
  model: String,
  instruction: String,
  medium: json.Json,
) -> Result(Reply, String) {
  let body =
    json.object([
      #(
        "system_instruction",
        json.object([
          #("parts", json.preprocessed_array([text_part(instruction)])),
        ]),
      ),
      #(
        "contents",
        json.preprocessed_array([
          json.object([
            #("role", json.string("user")),
            #("parts", json.preprocessed_array([medium])),
          ]),
        ]),
      ),
    ])
    |> json.to_string
  let url = client.base <> "/v1beta/models/" <> model <> ":generateContent"
  use answer <- result.try(call(client, Post, url, bit_array.from_string(body)))
  parse_reply(answer)
}

fn text_part(text: String) -> json.Json {
  json.object([#("text", json.string(text))])
}

/// The text of the first candidate (thought parts and parts without text
/// left out) and the token usage.
pub fn parse_reply(body: String) -> Result(Reply, String) {
  let part = {
    use text <- decode.optional_field("text", "", decode.string)
    use thought <- decode.optional_field("thought", False, decode.bool)
    decode.success(case thought {
      True -> ""
      False -> text
    })
  }
  let decoder = {
    use texts <- decode.optional_field(
      "candidates",
      [],
      decode.list(decode.optional_field(
        "content",
        [],
        {
          use parts <- decode.optional_field("parts", [], decode.list(part))
          decode.success(parts)
        },
        decode.success,
      )),
    )
    use usage <- decode.optional_field("usageMetadata", Usage(0, 0), {
      use input <- decode.optional_field("promptTokenCount", 0, decode.int)
      use output <- decode.optional_field("candidatesTokenCount", 0, decode.int)
      use thoughts <- decode.optional_field("thoughtsTokenCount", 0, decode.int)
      decode.success(Usage(input, output + thoughts))
    })
    decode.success(#(texts, usage))
  }
  case json.parse(body, decoder) {
    Ok(#([parts, ..], usage)) ->
      case string.trim(string.concat(parts)) {
        "" -> Error("Gemini answered without text")
        text -> Ok(Reply(text, usage))
      }
    Ok(#([], _)) -> Error("Gemini answered without text")
    Error(_) -> Error("Gemini answered in an unexpected format")
  }
}

type File {
  File(name: String, uri: String, state: String)
}

fn file_decoder() -> decode.Decoder(File) {
  use name <- decode.field("name", decode.string)
  use uri <- decode.field("uri", decode.string)
  use state <- decode.optional_field("state", "", decode.string)
  decode.success(File(name, uri, state))
}

fn upload_file(
  client: Client,
  path: String,
  mime: String,
  size: Int,
) -> Result(File, String) {
  use body <- result.try(upload(
    client.base <> "/upload/v1beta/files",
    client.api_key,
    path,
    mime,
    size,
  ))
  use text <- result.try(
    bit_array.to_string(body) |> result.replace_error("upload answer not text"),
  )
  json.parse(text, decode.at(["file"], file_decoder()))
  |> result.replace_error("upload answer without the file")
}

/// Pauses before each new look at a file being processed: about five
/// minutes in all, growing.
const waits = [
  500,
  1000,
  2000,
  4000,
  8000,
  15_000,
  30_000,
  60_000,
  60_000,
  60_000,
  60_000,
]

fn wait_active(
  client: Client,
  name: String,
  remaining: List(Int),
) -> Result(Nil, String) {
  let url = client.base <> "/v1beta/" <> name
  use answer <- result.try(call(client, Get, url, <<>>))
  case json.parse(answer, file_decoder()) {
    Ok(File(state: "ACTIVE", ..)) -> Ok(Nil)
    Ok(File(state: "FAILED", ..)) -> Error("Gemini could not process the file")
    _ ->
      case remaining {
        [] -> Error("the file was not ready in time")
        [pause, ..rest] -> {
          process.sleep(pause)
          wait_active(client, name, rest)
        }
      }
  }
}

fn delete_file(client: Client, name: String) -> Result(Nil, String) {
  case
    http(Delete, client.base <> "/v1beta/" <> name, client.api_key, "", <<>>)
  {
    // Already gone is what was asked: the API answered 403 for a deleted
    // file when the fixtures were recorded (24/11/2026); 404 too.
    Ok(#(status, _))
      if status >= 200 && status < 300 || status == 403 || status == 404
    -> Ok(Nil)
    Ok(#(status, _)) -> Error("delete answered " <> int.to_string(status))
    Error(reason) -> Error(reason)
  }
}

/// An authenticated call to the configured base only.
fn call(
  client: Client,
  method: Method,
  url: String,
  body: BitArray,
) -> Result(String, String) {
  case string.starts_with(url, client.base <> "/") {
    False -> Error("refused to send the key outside the Gemini API")
    True ->
      case http(method, url, client.api_key, "application/json", body) {
        Error(reason) -> Error("Gemini unreachable: " <> reason)
        Ok(#(200, answer)) ->
          bit_array.to_string(answer)
          |> result.replace_error("Gemini answer not text")
        Ok(#(status, answer)) -> Error(api_error(status, answer))
      }
  }
}

/// The API's own message for a failed call; never the body of a success.
fn api_error(status: Int, answer: BitArray) -> String {
  let message =
    bit_array.to_string(answer)
    |> result.try(fn(text) {
      json.parse(text, decode.at(["error", "message"], decode.string))
      |> result.replace_error(Nil)
    })
    |> result.map(fn(message) { ": " <> string.slice(message, 0, 200) })
    |> result.unwrap("")
  "Gemini answered " <> int.to_string(status) <> message
}
