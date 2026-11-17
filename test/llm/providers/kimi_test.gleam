import gleam/option
import gleeunit
import gleeunit/should
import supernova/llm/provider
import supernova/llm/providers/kimi

pub fn main() {
  gleeunit.main()
}

pub fn default_model_constant_test() {
  kimi.default_model |> should.equal("moonshot-v1-8k")
}

pub fn chat_requires_api_key_test() {
  let config =
    provider.ProviderConfig(
      name: "kimi",
      api_key: option.None,
      base_url: option.None,
      default_model: kimi.default_model,
    )

  kimi.chat([provider.user_message("hello")], config, [])
  |> should.equal(
    Error(provider.ConfigError(reason: "No API key configured for kimi")),
  )
}
