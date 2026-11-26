//// PRD-S, S-01: a tool with a full JSON Schema (arrays of objects, as the
//// Playwright MCP tools have) reaches every provider unchanged; a tool
//// with flat parameters goes out as before.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit/should
import supernova/llm/provider
import supernova/llm/providers/anthropic
import supernova/llm/providers/openai
import supernova/llm/stream

const form_schema =
  "{\"type\":\"object\",\"properties\":{\"fields\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"value\":{\"type\":\"string\"},\"checked\":{\"type\":\"boolean\"}},\"required\":[\"name\"]}},\"timeout\":{\"type\":\"number\"},\"retries\":{\"type\":\"integer\"},\"note\":{\"type\":[\"string\",\"null\"],\"default\":null}},\"required\":[\"fields\"],\"additionalProperties\":false}"

fn form_tool() -> provider.ToolDefinition {
  provider.tool_with_schema(
    name: "browser_fill_form",
    description: "Fill a form",
    schema: form_schema,
  )
}

fn flat_tool() -> provider.ToolDefinition {
  provider.new_tool(name: "flat", description: "Flat", parameters: [
    provider.string_param("q", "Query", True),
    provider.integer_param("n", "Count", False),
  ])
}

fn messages() -> List(provider.ChatMessage) {
  [provider.user_message("oi")]
}

/// The schema each body carries for the first tool, as a decoded value.
fn first_tool_schema(body: String, path: List(String)) -> json.Json {
  let decoder =
    decode.at(["tools"], decode.list(decode.at(path, decode.dynamic)))
  let assert Ok([schema, ..]) = json.parse(body, decoder)
  provider.dynamic_json(schema)
}

fn canonical(text: String) -> String {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  provider.dynamic_json(value) |> json.to_string
}

pub fn a_full_schema_reaches_every_provider_test() {
  let tools = [form_tool()]
  let expected = canonical(form_schema)
  [
    #(openai.build_request_body(messages(), "m", tools), [
      "function",
      "parameters",
    ]),
    #(stream.openai_stream_body(messages(), "m", tools), [
      "function",
      "parameters",
    ]),
    #(anthropic.build_request_body(messages(), "m", tools), ["input_schema"]),
    #(stream.anthropic_stream_body(messages(), "m", tools), ["input_schema"]),
  ]
  |> list.each(fn(case_) {
    first_tool_schema(case_.0, case_.1)
    |> json.to_string
    |> should.equal(expected)
  })
}

pub fn flat_parameters_go_out_as_before_test() {
  let expected =
    canonical(
      "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\",\"description\":\"Query\"},\"n\":{\"type\":\"integer\",\"description\":\"Count\"}},\"required\":[\"q\"]}",
    )
  first_tool_schema(openai.build_request_body(messages(), "m", [flat_tool()]), [
    "function",
    "parameters",
  ])
  |> json.to_string
  |> should.equal(expected)
  first_tool_schema(
    anthropic.build_request_body(messages(), "m", [flat_tool()]),
    ["input_schema"],
  )
  |> json.to_string
  |> should.equal(expected)
}

/// A schema that is not a JSON object falls back to the flat parameters,
/// so a broken server never sends the model something invalid.
pub fn a_broken_schema_falls_back_test() {
  [
    "nada",
    "[1,2]",
    "\"texto\"",
  ]
  |> list.each(fn(text) {
    provider.ToolDefinition(..flat_tool(), schema: Some(text))
    |> provider.parameters_schema
    |> json.to_string
    |> should.equal(provider.parameters_schema(flat_tool()) |> json.to_string)
  })
}

pub fn dynamic_json_keeps_every_kind_test() {
  canonical(
    "{\"b\":true,\"i\":3,\"f\":1.5,\"s\":\"x\",\"l\":[1,\"a\"],\"n\":null}",
  )
  |> should.equal(
    "{\"b\":true,\"f\":1.5,\"i\":3,\"l\":[1,\"a\"],\"n\":null,\"s\":\"x\"}",
  )
}
