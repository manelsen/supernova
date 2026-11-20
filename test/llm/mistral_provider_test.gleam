import gleam/option.{None}
import gleeunit/should
import supernova/config
import supernova/llm/client
import supernova/llm/provider

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
