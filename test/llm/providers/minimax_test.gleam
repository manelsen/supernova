import gleeunit
import gleeunit/should
import gleam/option
import supernova/llm/provider
import supernova/llm/providers/minimax

pub fn main() {
  gleeunit.main()
}

pub fn default_model_constant_test() {
  minimax.default_model |> should.equal("MiniMax-Text-01")
}

pub fn chat_requires_api_key_test() {
  let config =
    provider.ProviderConfig(
      name: "minimax",
      api_key: option.None,
      base_url: option.None,
      default_model: minimax.default_model,
    )

  minimax.chat([provider.user_message("hello")], config, [])
  |> should.equal(
    Error(provider.ConfigError(reason: "No API key configured for minimax")),
  )
}
