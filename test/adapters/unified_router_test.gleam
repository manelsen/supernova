import gleam/option
import gleeunit/should
import supernova/adapters/unified_router
import supernova/channel/session
import supernova/llm/provider

pub fn start_without_manager_test() {
  let resolver = session.without_manager("matrix")
  let config =
    provider.ProviderConfig(
      name: "test",
      api_key: option.None,
      base_url: option.None,
      default_model: "gpt-4",
    )

  let result = unified_router.start("matrix", config, resolver)

  result
  |> should.be_ok()
}

pub fn start_with_empty_channel_test() {
  let resolver = session.without_manager("")
  let config =
    provider.ProviderConfig(
      name: "test",
      api_key: option.None,
      base_url: option.None,
      default_model: "gpt-4",
    )

  let result = unified_router.start("", config, resolver)

  result
  |> should.be_ok()
}

pub fn session_resolver_integration_test() {
  let resolver =
    session.with_manager(fn(channel_id, user_id) {
      "custom:" <> channel_id <> ":" <> user_id
    })
  let config =
    provider.ProviderConfig(
      name: "test",
      api_key: option.None,
      base_url: option.None,
      default_model: "gpt-4",
    )

  let result = unified_router.start("test", config, resolver)

  result
  |> should.be_ok()
}
