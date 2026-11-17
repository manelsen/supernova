import gleam/option
import gleeunit
import gleeunit/should
import supernova/llm/provider
import supernova/llm/providers/ollama

pub fn main() {
  gleeunit.main()
}

pub fn chat_returns_error_when_endpoint_is_unreachable_test() {
  let config =
    provider.ProviderConfig(
      name: "ollama",
      api_key: option.None,
      base_url: option.Some("http://127.0.0.1:1/v1/chat/completions"),
      default_model: "llama3.1",
    )

  ollama.chat([provider.user_message("hello")], config, [])
  |> should.be_error
}
