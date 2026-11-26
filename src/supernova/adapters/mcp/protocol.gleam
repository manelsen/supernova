//// The MCP protocol, apart from the transport (PRD-S, S-02): what is sent
//// and how answers are read, the same for a server over stdio here and for
//// one inside the computer (`mcp/computer`).

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import supernova/llm/provider

/// The version Supernova asks for first.
pub const latest_version = "2025-11-25"

/// Versions a server may answer with (the official SDK's list, 1.32.2).
pub fn supported_versions() -> List(String) {
  [latest_version, "2025-06-18", "2025-03-26", "2024-11-05"]
}

pub fn initialize_params() -> json.Json {
  json.object([
    #("protocolVersion", json.string(latest_version)),
    #("capabilities", json.object([])),
    #(
      "clientInfo",
      json.object([
        #("name", json.string("supernova")),
        #("version", json.string("1.0.0")),
      ]),
    ),
  ])
}

pub fn request(id: Int, method: String, params: json.Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(id)),
    #("method", json.string(method)),
    #("params", params),
  ])
  |> json.to_string
}

pub fn notification(method: String) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string(method)),
  ])
  |> json.to_string
}

/// The version the server chose, if Supernova speaks it.
pub fn check_initialize(result_json: String) -> Result(String, String) {
  case json.parse(result_json, decode.at(["protocolVersion"], decode.string)) {
    Ok(version) ->
      case list.contains(supported_versions(), version) {
        True -> Ok(version)
        False -> Error("Unsupported MCP protocol version: " <> version)
      }
    Error(_) -> Error("Missing protocolVersion in initialize response")
  }
}

/// The `result` of a JSON-RPC answer as JSON text, or the error's message.
pub fn result_of(answer: String) -> Result(String, String) {
  let error =
    decode.at(["error"], {
      use message <- decode.optional_field(
        "message",
        "JSON-RPC error in response",
        decode.string,
      )
      use code <- decode.optional_field("code", 0, decode.int)
      decode.success(#(code, message))
    })
  case json.parse(answer, error) {
    Ok(#(code, message)) ->
      Error(case code {
        0 -> message
        _ -> message <> " (" <> int.to_string(code) <> ")"
      })
    Error(_) ->
      case json.parse(answer, decode.at(["result"], decode.dynamic)) {
        Ok(value) -> Ok(json.to_string(provider.dynamic_json(value)))
        Error(_) -> Error("Invalid JSON-RPC response")
      }
  }
}

/// The tools of a `tools/list` result, named by `naming` (the server's name
/// is the argument), each with its full argument schema.
pub fn tools(
  result_json: String,
  naming: fn(String) -> String,
) -> Result(List(provider.ToolDefinition), String) {
  let tool = {
    use name <- decode.field("name", decode.string)
    use description <- decode.optional_field("description", "", decode.string)
    use schema <- decode.optional_field(
      "inputSchema",
      None,
      decode.dynamic |> decode.map(Some),
    )
    decode.success(provider.ToolDefinition(
      name: naming(name),
      description: description,
      parameters: [],
      schema: option.map(schema, fn(value) {
        json.to_string(provider.dynamic_json(value))
      }),
    ))
  }
  json.parse(result_json, decode.at(["tools"], decode.list(tool)))
  |> option_error("tools/list answer has no readable tools")
}

/// The text of a `tools/call` result: its text items, one per line. Other
/// items (images, resources) are named, not inlined. A result marked
/// `isError` is an error.
pub fn call_text(result_json: String) -> Result(String, String) {
  let item = {
    use kind <- decode.optional_field("type", "text", decode.string)
    use text <- decode.optional_field("text", "", decode.string)
    decode.success(case kind {
      "text" -> text
      other -> "[" <> other <> " omitido]"
    })
  }
  let decoder = {
    use items <- decode.optional_field("content", [], decode.list(item))
    use is_error <- decode.optional_field("isError", False, decode.bool)
    decode.success(#(string.join(items, "\n"), is_error))
  }
  case json.parse(result_json, decoder) {
    Ok(#(text, False)) -> Ok(text)
    Ok(#(text, True)) -> Error(text)
    Error(_) -> Error("tools/call answer is not readable")
  }
}

fn option_error(
  value: Result(a, json.DecodeError),
  message: String,
) -> Result(a, String) {
  case value {
    Ok(inner) -> Ok(inner)
    Error(_) -> Error(message)
  }
}
