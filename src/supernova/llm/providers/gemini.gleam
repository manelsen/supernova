//// Gemini Provider — the Gemini API itself (`generateContent`), as Amélie
//// uses it: the key in the `x-goog-api-key` header, never in the URL, and
//// only for Google's API host.
////
//// - System messages become `systemInstruction`; the assistant is `model`.
//// - Tools are `functionDeclarations` with a JSON Schema
////   (`parametersJsonSchema`); a call is a `functionCall` part, its result a
////   `functionResponse` part, and the results of one step go together in
////   one turn.
//// - Gemini 3 signs its calls: the part with the first call of a step
////   carries a `thoughtSignature` that must go back in the same part, or the
////   next request is refused. The signature rides in the call's id
////   (`signature_separator`) until it is sent back. A step rebuilt from the
////   session history has none: its first call gets the value Google
////   documents for calls the model did not just make.
//// - Thought parts are left out of the answer.

import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/llm/provider

/// Every Gemini API URL starts here; the key goes nowhere else.
pub const api_base = "https://generativelanguage.googleapis.com/"

/// The signature Google accepts for a call the model did not just make
/// (https://aistudio.google.com/docs/thought-signatures).
pub const history_signature = "skip_thought_signature_validator"

/// What separates a call's id from its thought signature.
pub const signature_separator = "~sig~"

pub fn chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  let base = option.unwrap(config.base_url, api_base)
  case config.api_key, string.starts_with(base, api_base) {
    None, _ ->
      Error(provider.ConfigError(reason: "No API key configured for gemini"))
    _, False ->
      Error(provider.ConfigError(
        reason: "Refusing to send the gemini API key outside " <> api_base,
      ))
    Some(key), True -> {
      let url =
        api_base
        <> "v1beta/models/"
        <> config.default_model
        <> ":generateContent"
      build_request_body(messages, tools)
      |> post(url, key)
      |> result.try(parse_response)
    }
  }
}

// ============================================================================
// Request
// ============================================================================

/// The `generateContent` body. Exported for testing.
pub fn build_request_body(
  messages: List(provider.ChatMessage),
  tools: List(provider.ToolDefinition),
) -> String {
  let system =
    messages
    |> list.filter(fn(m) { m.role == "system" })
    |> list.map(fn(m) { m.content })
    |> string.join("\n\n")
  let rest = list.filter(messages, fn(m) { m.role != "system" })
  let names = call_names(rest)
  let fields = [#("contents", json.preprocessed_array(contents(rest, names)))]
  let fields = case system {
    "" -> fields
    text -> [
      #(
        "systemInstruction",
        json.object([#("parts", parts([text_part(text)]))]),
      ),
      ..fields
    ]
  }
  let fields = case tools {
    [] -> fields
    _ ->
      list.append(fields, [
        #(
          "tools",
          json.preprocessed_array([
            json.object([
              #("functionDeclarations", json.array(tools, declaration)),
            ]),
          ]),
        ),
      ])
  }
  json.object(fields) |> json.to_string
}

/// The name of every call by its bare id: a function's result names it.
fn call_names(
  messages: List(provider.ChatMessage),
) -> dict.Dict(String, String) {
  messages
  |> list.flat_map(fn(m) { option.unwrap(m.tool_calls, []) })
  |> list.map(fn(call) { #(split_signature(call.id).0, call.name) })
  |> dict.from_list
}

/// One content per turn: consecutive messages of the same role (the
/// results of one step, above all) go together.
fn contents(
  messages: List(provider.ChatMessage),
  names: dict.Dict(String, String),
) -> List(json.Json) {
  messages
  |> list.map(fn(m) { #(role(m), message_parts(m, names)) })
  |> list.fold([], fn(acc, item) {
    case acc, item {
      [#(last_role, last_parts), ..before], #(this_role, these)
        if last_role == this_role
      -> [#(last_role, list.append(last_parts, these)), ..before]
      _, _ -> [item, ..acc]
    }
  })
  |> list.reverse
  |> list.filter(fn(turn) { turn.1 != [] })
  |> list.map(fn(turn) {
    json.object([#("role", json.string(turn.0)), #("parts", parts(turn.1))])
  })
}

fn role(message: provider.ChatMessage) -> String {
  case message.role {
    "assistant" -> "model"
    _ -> "user"
  }
}

fn parts(items: List(json.Json)) -> json.Json {
  json.preprocessed_array(items)
}

fn text_part(text: String) -> json.Json {
  json.object([#("text", json.string(text))])
}

fn message_parts(
  message: provider.ChatMessage,
  names: dict.Dict(String, String),
) -> List(json.Json) {
  case message.role, message.tool_call_id {
    "tool", Some(id) -> {
      let bare = split_signature(id).0
      let name = dict.get(names, bare) |> result.unwrap("tool")
      [
        json.object([
          #(
            "functionResponse",
            json.object([
              #("id", json.string(bare)),
              #("name", json.string(name)),
              #(
                "response",
                json.object([#("result", json.string(message.content))]),
              ),
            ]),
          ),
        ]),
      ]
    }
    _, _ -> {
      let text = case message.content {
        "" -> []
        content -> [text_part(content)]
      }
      let images = list.filter_map(message.images, image_part)
      let calls = case message.tool_calls {
        Some(calls) -> signed_calls(calls)
        None -> []
      }
      list.flatten([text, images, calls])
    }
  }
}

/// A data URL (`data:image/jpeg;base64,...`) as inline data.
fn image_part(url: String) -> Result(json.Json, Nil) {
  use #(head, data) <- result.try(string.split_once(url, ","))
  use mime <- result.try(case head {
    "data:" <> rest ->
      case string.split_once(rest, ";") {
        Ok(#(mime, _)) -> Ok(mime)
        Error(Nil) -> Ok(rest)
      }
    _ -> Error(Nil)
  })
  Ok(
    json.object([
      #(
        "inlineData",
        json.object([
          #("mimeType", json.string(mime)),
          #("data", json.string(data)),
        ]),
      ),
    ]),
  )
}

/// The calls of one step, the first one signed.
fn signed_calls(calls: List(provider.ToolCall)) -> List(json.Json) {
  list.index_map(calls, fn(call, index) {
    let #(id, signature) = split_signature(call.id)
    let signature = case signature, index {
      Some(signature), _ -> Some(signature)
      None, 0 -> Some(history_signature)
      None, _ -> None
    }
    let function =
      json.object([
        #("id", json.string(id)),
        #("name", json.string(call.name)),
        #("args", arguments(call.arguments)),
      ])
    json.object(case signature {
      Some(signature) -> [
        #("functionCall", function),
        #("thoughtSignature", json.string(signature)),
      ]
      None -> [#("functionCall", function)]
    })
  })
}

/// A call's arguments as an object; text that is not one goes as `{}`.
fn arguments(text: String) -> json.Json {
  let object = decode.dict(decode.string, decode.dynamic)
  case json.parse(text, object) {
    Ok(_) -> raw(text)
    Error(_) -> json.object([])
  }
}

/// JSON text already checked, sent as it is (gleam_json's Json is iodata).
@external(erlang, "supernova_gemini_ffi", "raw")
fn raw(text: String) -> json.Json

fn declaration(tool: provider.ToolDefinition) -> json.Json {
  json.object([
    #("name", json.string(tool.name)),
    #("description", json.string(tool.description)),
    #("parametersJsonSchema", provider.parameters_schema(tool)),
  ])
}

// ============================================================================
// HTTP
// ============================================================================

fn post(
  body: String,
  url: String,
  key: String,
) -> Result(String, provider.LLMError) {
  let assert Ok(req) = request.to(url)
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("x-goog-api-key", key)
    |> request.set_body(body)
  case hackney.send(req) {
    Ok(response) ->
      case response.status {
        200 -> Ok(response.body)
        status ->
          Error(provider.APIError(
            status: status,
            message: error_message(response.body),
          ))
      }
    Error(_) ->
      Error(provider.NetworkError(reason: "Network error connecting to Gemini"))
  }
}

fn error_message(body: String) -> String {
  let decoder = decode.at(["error", "message"], decode.string)
  case json.parse(body, decoder) {
    Ok(message) -> message
    Error(_) -> string.slice(body, 0, 300)
  }
}

// ============================================================================
// Response
// ============================================================================

type Part {
  Text(String)
  Call(id: String, name: String, arguments: String, signature: Option(String))
  Skip
}

/// The answer: the text of the first candidate (thoughts left out) and its
/// calls, each id carrying its signature. Exported for testing.
pub fn parse_response(
  body: String,
) -> Result(provider.ChatResponse, provider.LLMError) {
  let decoder =
    decode.at(
      ["candidates"],
      decode.list(decode.at(["content", "parts"], decode.list(part_decoder()))),
    )
  case json.parse(body, decoder) {
    Ok([found, ..]) -> Ok(to_response(found))
    Ok([]) ->
      Error(provider.APIError(
        status: 0,
        message: "Gemini answered no candidate",
      ))
    Error(_) ->
      Error(provider.APIError(
        status: 0,
        message: "Failed to parse Gemini response",
      ))
  }
}

fn to_response(found: List(Part)) -> provider.ChatResponse {
  let text =
    found
    |> list.filter_map(fn(part) {
      case part {
        Text(text) -> Ok(text)
        _ -> Error(Nil)
      }
    })
    |> string.concat
  let calls =
    found
    |> list.filter_map(fn(part) {
      case part {
        Call(..) -> Ok(part)
        _ -> Error(Nil)
      }
    })
    |> list.index_map(fn(part, index) {
      let assert Call(id, name, arguments, signature) = part
      let id = case id {
        "" -> "g" <> int.to_string(index + 1)
        id -> id
      }
      provider.ToolCall(
        id: case signature {
          Some(signature) -> id <> signature_separator <> signature
          None -> id
        },
        name: name,
        arguments: arguments,
      )
    })
  provider.ChatResponse(
    role: "assistant",
    content: text,
    tool_calls: case calls {
      [] -> None
      calls -> Some(calls)
    },
    reasoning_content: None,
  )
}

fn part_decoder() -> decode.Decoder(Part) {
  use thought <- decode.optional_field("thought", False, decode.bool)
  use text <- decode.optional_field(
    "text",
    None,
    decode.optional(decode.string),
  )
  use signature <- decode.optional_field(
    "thoughtSignature",
    None,
    decode.optional(decode.string),
  )
  use call <- decode.optional_field(
    "functionCall",
    None,
    decode.optional({
      use id <- decode.optional_field("id", "", decode.string)
      use name <- decode.field("name", decode.string)
      use args <- decode.optional_field(
        "args",
        dynamic.properties([]),
        decode.dynamic,
      )
      decode.success(#(id, name, encode_dynamic(args)))
    }),
  )
  decode.success(case thought, call, text {
    _, Some(#(id, name, arguments)), _ -> Call(id, name, arguments, signature)
    True, None, _ -> Skip
    False, None, Some(text) -> Text(text)
    False, None, None -> Skip
  })
}

@external(erlang, "supernova_gemini_ffi", "to_json")
fn encode_dynamic(value: dynamic.Dynamic) -> String

/// A call's id and the thought signature it carries, if any.
pub fn split_signature(id: String) -> #(String, Option(String)) {
  case string.split_once(id, signature_separator) {
    Ok(#(bare, signature)) -> #(bare, Some(signature))
    Error(Nil) -> #(id, None)
  }
}
