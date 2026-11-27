//// The Gemini provider speaks the Gemini API itself (generateContent).
//// Shapes checked against the live API on 27/11/2026 (gemini-3.8-flash).

import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/llm/provider
import supernova/llm/providers/gemini

fn hora() -> provider.ToolDefinition {
  provider.new_tool(
    name: "hora",
    description: "Current time in a city",
    parameters: [provider.string_param("cidade", "city name", True)],
  )
}

pub fn system_messages_become_the_system_instruction_test() {
  let body =
    gemini.build_request_body(
      [provider.system_message("Seja breve."), provider.user_message("Oi")],
      [],
    )
  string.contains(
    body,
    "\"systemInstruction\":{\"parts\":[{\"text\":\"Seja breve.\"}]}",
  )
  |> should.be_true
  string.contains(
    body,
    "\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"Oi\"}]}]",
  )
  |> should.be_true
}

pub fn tools_are_function_declarations_with_a_json_schema_test() {
  let body = gemini.build_request_body([provider.user_message("Oi")], [hora()])
  string.contains(body, "\"functionDeclarations\":[{\"name\":\"hora\"")
  |> should.be_true
  string.contains(body, "\"parametersJsonSchema\":") |> should.be_true
}

pub fn an_image_goes_as_inline_data_test() {
  let body =
    gemini.build_request_body(
      [
        provider.user_message_with_images("O que é?", [
          "data:image/png;base64,AAAA",
        ]),
      ],
      [],
    )
  string.contains(
    body,
    "{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"AAAA\"}}",
  )
  |> should.be_true
}

// The first call of a step carries the model's thought signature; the
// parallel calls after it carry none (as the API sends them).
pub fn calls_keep_their_signatures_test() {
  let assert Ok(answer) =
    gemini.parse_response(
      "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":["
      <> "{\"functionCall\":{\"name\":\"hora\",\"args\":{\"cidade\":\"BH\"}},\"thoughtSignature\":\"SIG1\"},"
      <> "{\"functionCall\":{\"name\":\"hora\",\"args\":{\"cidade\":\"Lisboa\"}}}"
      <> "]}}]}",
    )
  let assert Some([first, second]) = answer.tool_calls
  gemini.split_signature(first.id) |> should.equal(#("g1", Some("SIG1")))
  gemini.split_signature(second.id) |> should.equal(#("g2", None))
  first.arguments |> should.equal("{\"cidade\":\"BH\"}")

  let body =
    gemini.build_request_body(
      [
        provider.user_message("Hora?"),
        provider.assistant_message_with_tools("", [first, second]),
        provider.tool_result_message(first.id, "20:47"),
        provider.tool_result_message(second.id, "00:47"),
      ],
      [hora()],
    )
  string.contains(body, "\"thoughtSignature\":\"SIG1\"") |> should.be_true
  string.contains(body, "~sig~") |> should.be_false
  // The results of one step go together, in one user turn, by name.
  string.contains(
    body,
    "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"id\":\"g1\",\"name\":\"hora\",\"response\":{\"result\":\"20:47\"}}},{\"functionResponse\":{\"id\":\"g2\",\"name\":\"hora\",\"response\":{\"result\":\"00:47\"}}}]}",
  )
  |> should.be_true
}

// A step rebuilt from the session history has no signature: its first call
// gets the one Google documents for calls the model did not just make.
pub fn a_call_from_history_gets_the_documented_signature_test() {
  let body =
    gemini.build_request_body(
      [
        provider.user_message("Hora?"),
        provider.assistant_message_with_tools("", [
          provider.ToolCall(id: "h00000001", name: "hora", arguments: "{}"),
        ]),
        provider.tool_result_message("h00000001", "20:47"),
      ],
      [hora()],
    )
  string.contains(
    body,
    "\"thoughtSignature\":\"skip_thought_signature_validator\"",
  )
  |> should.be_true
}

pub fn thoughts_are_left_out_of_the_answer_test() {
  gemini.parse_response(
    "{\"candidates\":[{\"content\":{\"parts\":["
    <> "{\"text\":\"pensando...\",\"thought\":true},{\"text\":\"Olá!\"}]}}]}",
  )
  |> should.equal(
    Ok(provider.ChatResponse(
      role: "assistant",
      content: "Olá!",
      tool_calls: None,
      reasoning_content: None,
    )),
  )
}

pub fn the_key_never_leaves_googles_api_test() {
  gemini.chat(
    [provider.user_message("Oi")],
    provider.ProviderConfig(
      name: "gemini",
      api_key: Some("k"),
      base_url: Some("https://example.com/"),
      default_model: "gemini-3.8-flash",
    ),
    [],
  )
  |> should.be_error
}
