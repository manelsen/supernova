//// The provider every agent uses must be usable before the runtime starts.

import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/config

fn with_providers(
  providers: List(#(String, config.ProviderConfig)),
) -> config.Config {
  config.Config(..config.default_config(), providers: dict.from_list(providers))
}

fn provider(kind: config.Provider, key) -> config.ProviderConfig {
  config.ProviderConfig(
    provider: kind,
    api_key: key,
    base_url: None,
    model: None,
    timeout_ms: 1000,
  )
}

pub fn selects_first_provider_by_name_test() {
  let cfg =
    with_providers([
      #("mistral", provider(config.Mistral, Some("k1"))),
      #("anthropic", provider(config.Anthropic, Some("k2"))),
    ])
  let assert Ok(#(name, _)) = config.selected_provider(cfg)
  name |> should.equal("anthropic")
}

pub fn refuses_selected_provider_without_key_test() {
  let cfg =
    with_providers([
      #("mistral", provider(config.Mistral, Some("k1"))),
      #("anthropic", provider(config.Anthropic, None)),
    ])
  let assert Error(message) = config.selected_provider(cfg)
  string.contains(message, "SUPERNOVA_PROVIDER_ANTHROPIC_API_KEY")
  |> should.be_true()
  string.contains(message, "mistral") |> should.be_true()
}

pub fn blank_key_counts_as_missing_test() {
  let cfg =
    with_providers([#("opencode-zen", provider(config.OpenCodeZen, Some("  ")))])
  let assert Error(message) = config.selected_provider(cfg)
  string.contains(message, "SUPERNOVA_PROVIDER_OPENCODE_ZEN_API_KEY")
  |> should.be_true()
}

pub fn keyless_providers_are_accepted_test() {
  let cfg = with_providers([#("local", provider(config.Ollama, None))])
  let assert Ok(#("local", _)) = config.selected_provider(cfg)
  let cfg = with_providers([#("mock", provider(config.Mock, None))])
  let assert Ok(#("mock", _)) = config.selected_provider(cfg)
}

pub fn no_provider_is_an_error_test() {
  let assert Error(message) = config.selected_provider(with_providers([]))
  string.contains(message, "no LLM providers configured") |> should.be_true()
}

pub fn enabled_channel_without_credentials_is_reported_test() {
  let base = config.default_config()
  let cfg =
    config.Config(
      ..base,
      telegram: config.TelegramConfig(
        enabled: True,
        token: None,
        base_url: None,
      ),
      mattermost: config.MattermostConfig(
        enabled: True,
        token: Some("t"),
        base_url: None,
      ),
    )
  config.incomplete_channels(cfg)
  |> should.equal([
    #("telegram", "enabled but missing token"),
    #("mattermost", "enabled but missing base_url"),
  ])
}

pub fn disabled_or_complete_channels_are_not_reported_test() {
  let base = config.default_config()
  let cfg =
    config.Config(
      ..base,
      telegram: config.TelegramConfig(
        enabled: True,
        token: Some("t"),
        base_url: None,
      ),
    )
  config.incomplete_channels(cfg) |> should.equal([])
}
