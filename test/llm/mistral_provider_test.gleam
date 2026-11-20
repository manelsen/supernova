import gleam/option.{None, Some}
import gleeunit/should
import supernova/config
import supernova/llm/client
import supernova/llm/provider
import supernova/llm/providers/openai
import supernova/llm/providers/openai_compatible

// The agents run on DeepSeek through Mistral's OpenAI-compatible API since
// the first battery (MiniMax-M3 broke the core text).
pub fn mistral_is_a_known_provider_test() {
  let assert Ok(parsed) = config.provider_from_name("mistral")
  parsed |> should.equal(config.Mistral)
  config.provider_runtime_name(parsed) |> should.equal("mistral")
  config.provider_requires_api_key(parsed) |> should.be_true()
  config.provider_default_model(parsed)
  |> should.equal("deepseek-v4-1-flash-1017")
}

pub fn mistral_dispatches_to_the_compatible_client_test() {
  // No key: the compatible client refuses before any network call. The point
  // is that the dispatcher knows the provider.
  let result =
    client.chat(
      [provider.user_message("oi")],
      provider.ProviderConfig(
        name: "mistral",
        api_key: None,
        base_url: None,
        default_model: "deepseek-v4-1-flash-1017",
      ),
      [],
    )
  case result {
    Error(provider.ProviderNotFound(_)) -> should.fail()
    Error(provider.ConfigError(reason)) ->
      reason |> should.equal("No API key configured for mistral")
    _ -> should.fail()
  }
  client.mistral_chat_url
  |> should.equal("https://api.mistral.ai/v1/chat/completions")
}

// Regression from the third battery: a real Mistral answer carries
// "tool_calls": null, and every agent turn failed to parse.
pub fn real_mistral_answer_parses_test() {
  let assert Ok(body) = read_file("test/fixtures/llm/mistral_deepseek_ok.json")
  let assert Ok(response) = openai.parse_response(body)
  response.content |> should.equal("OK")
  response.tool_calls |> should.equal(None)
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

// From review: only "tool_calls": null was covered; content and
// reasoning_content may be null too.
pub fn null_content_with_tool_calls_parses_test() {
  let body =
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,"
    <> "\"reasoning_content\":null,\"tool_calls\":[{\"id\":\"c1\","
    <> "\"type\":\"function\",\"function\":{\"name\":\"file_system\","
    <> "\"arguments\":\"{\\\"action\\\":\\\"list\\\"}\"}}]}}]}"
  let assert Ok(response) = openai.parse_response(body)
  response.content |> should.equal("")
  response.reasoning_content |> should.equal(None)
  response.tool_calls
  |> should.equal(
    Some([
      provider.ToolCall(
        id: "c1",
        name: "file_system",
        arguments: "{\"action\":\"list\"}",
      ),
    ]),
  )
}

// From review: a base_url override over plain HTTP sent the key in cleartext.
pub fn the_key_travels_only_over_https_test() {
  openai_compatible.secure_endpoint("mistral", "https://api.mistral.ai/v1")
  |> should.be_ok()
  openai_compatible.secure_endpoint("mistral", "http://gateway.example/v1")
  |> should.be_error()
  openai_compatible.secure_endpoint("mistral", "http://localhost:8080/v1")
  |> should.be_ok()
  openai_compatible.secure_endpoint("mistral", "http://localhost.evil.com/v1")
  |> should.be_error()
  openai_compatible.secure_endpoint("ollama", "http://ollama:11434/v1")
  |> should.be_ok()
}
