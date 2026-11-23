import gleam/dict
import gleam/option.{None, Some}
import gleeunit/should
import supernova/config
import supernova/llm/catalog
import supernova/llm/provider

fn entry(
  kind: config.Provider,
  key: option.Option(String),
  model: option.Option(String),
  models: List(String),
) -> config.ProviderConfig {
  config.ProviderConfig(
    provider: kind,
    api_key: key,
    base_url: None,
    model: model,
    models: models,
    timeout_ms: 1000,
  )
}

fn cfg(providers: List(#(String, config.ProviderConfig))) -> config.Config {
  config.Config(..config.default_config(), providers: dict.from_list(providers))
}

fn mistral() -> config.ProviderConfig {
  entry(config.Mistral, Some("mistral-key"), Some("deepseek-flash"), [
    "deepseek-pro", "deepseek-flash", " ", "mistral-large",
  ])
}

fn openai() -> config.ProviderConfig {
  entry(config.OpenAI, Some("openai-key"), Some("gpt-x"), [])
}

pub fn default_comes_first_and_lists_its_models_once_test() {
  let default = catalog.runtime_config(mistral())
  let cat =
    catalog.from_config(
      cfg([#("openai", openai()), #("mistral", mistral())]),
      default,
    )
  catalog.providers(cat) |> should.equal(["mistral", "openai"])
  // The configured model first, repeats and blanks dropped.
  catalog.models(cat, "mistral")
  |> should.equal(["deepseek-flash", "deepseek-pro", "mistral-large"])
  catalog.models(cat, "openai") |> should.equal(["gpt-x"])
  catalog.models(cat, "anthropic") |> should.equal([])
}

pub fn providers_without_a_key_are_left_out_test() {
  let default = catalog.runtime_config(mistral())
  let keyless = entry(config.Anthropic, None, Some("claude-x"), [])
  let blank = entry(config.OpenAI, Some("  "), Some("gpt-x"), [])
  let local = entry(config.Ollama, None, Some("llama"), [])
  let cat =
    catalog.from_config(
      cfg([
        #("anthropic", keyless),
        #("mistral", mistral()),
        #("ollama", local),
        #("openai", blank),
      ]),
      default,
    )
  catalog.providers(cat) |> should.equal(["mistral", "ollama"])
}

/// Each provider is called with its own key and address, never another's.
pub fn resolve_uses_the_providers_own_key_test() {
  let default = catalog.runtime_config(mistral())
  let cat =
    catalog.from_config(
      cfg([#("mistral", mistral()), #("openai", openai())]),
      default,
    )
  let assert Some(chosen) =
    catalog.resolve(cat, catalog.Choice("openai", "gpt-x"))
  chosen.name |> should.equal("openai")
  chosen.api_key |> should.equal(Some("openai-key"))
  chosen.default_model |> should.equal("gpt-x")

  let assert Some(chosen) =
    catalog.resolve(cat, catalog.Choice("mistral", "mistral-large"))
  chosen.api_key |> should.equal(Some("mistral-key"))
  chosen.default_model |> should.equal("mistral-large")
}

pub fn resolve_refuses_what_is_not_configured_test() {
  let default = catalog.runtime_config(mistral())
  let cat =
    catalog.from_config(
      cfg([#("mistral", mistral()), #("openai", openai())]),
      default,
    )
  catalog.resolve(cat, catalog.Choice("openai", "deepseek-pro"))
  |> should.equal(None)
  catalog.resolve(cat, catalog.Choice("anthropic", "claude-x"))
  |> should.equal(None)
  catalog.resolve(cat, catalog.Choice("mistral", "gpt-x")) |> should.equal(None)
}

pub fn choices_cover_every_pair_test() {
  let default = catalog.runtime_config(mistral())
  let cat =
    catalog.from_config(
      cfg([#("mistral", mistral()), #("openai", openai())]),
      default,
    )
  catalog.choices(cat)
  |> should.equal([
    catalog.Choice("mistral", "deepseek-flash"),
    catalog.Choice("mistral", "deepseek-pro"),
    catalog.Choice("mistral", "mistral-large"),
    catalog.Choice("openai", "gpt-x"),
  ])
}

pub fn current_falls_back_to_the_default_alone_test() {
  let default =
    provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock-model",
    )
  catalog.clear_global()
  catalog.current(default) |> should.equal(catalog.single(default))

  // A catalog published for another default is not used.
  let other = catalog.runtime_config(mistral())
  catalog.set_global(catalog.from_config(cfg([#("mistral", mistral())]), other))
  catalog.current(default) |> should.equal(catalog.single(default))
  catalog.providers(catalog.current(other)) |> should.equal(["mistral"])
  catalog.clear_global()
}

pub fn yaml_models_list_is_read_test() {
  let yaml =
    "providers:\n  mistral:\n    api_key: k\n    model: deepseek-flash\n    models:\n      - deepseek-pro\n      - mistral-large\n"
  let assert Ok(parsed) = config.parse_yaml(yaml)
  let assert Ok(mistral) = dict.get(parsed.providers, "mistral")
  mistral.models |> should.equal(["deepseek-pro", "mistral-large"])
}
