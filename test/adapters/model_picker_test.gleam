import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/model_picker
import supernova/llm/catalog
import supernova/llm/provider

fn config(name: String, model: String) -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: name,
    api_key: Some(name <> "-key"),
    base_url: None,
    default_model: model,
  )
}

fn cat() -> catalog.Catalog {
  catalog.Catalog(default: config("mistral", "deepseek-flash"), entries: [
    catalog.Entry(config: config("mistral", "deepseek-flash"), models: [
      "deepseek-flash", "deepseek-pro",
    ]),
    catalog.Entry(config: config("openrouter", "openai/gpt-x"), models: [
      "openai/gpt-x", "deepseek-pro",
    ]),
  ])
}

pub fn parse_test() {
  model_picker.parse("/model") |> should.equal(Some(model_picker.Show))
  model_picker.parse(" /models ") |> should.equal(Some(model_picker.Show))
  model_picker.parse("/model@selene_bot")
  |> should.equal(Some(model_picker.Show))
  model_picker.parse("modelo") |> should.equal(Some(model_picker.Show))
  model_picker.parse("/model deepseek-pro")
  |> should.equal(Some(model_picker.Pick("deepseek-pro")))
  model_picker.parse("/MODEL   openrouter openai/gpt-x ")
  |> should.equal(Some(model_picker.Pick("openrouter openai/gpt-x")))
  model_picker.parse("/model@selene_bot deepseek-pro")
  |> should.equal(Some(model_picker.Pick("deepseek-pro")))
  model_picker.parse("qual modelo você usa?") |> should.equal(None)
  model_picker.parse("/modelagem") |> should.equal(None)
}

/// A bare model is looked for first at the provider in use.
pub fn typed_model_prefers_the_active_provider_test() {
  let active = config("mistral", "deepseek-flash")
  let assert Some(chosen) =
    model_picker.resolve_typed(cat(), active, "deepseek-pro")
  chosen.name |> should.equal("mistral")

  let active = config("openrouter", "openai/gpt-x")
  let assert Some(chosen) =
    model_picker.resolve_typed(cat(), active, "deepseek-pro")
  chosen.name |> should.equal("openrouter")
  chosen.api_key |> should.equal(Some("openrouter-key"))
}

pub fn typed_model_finds_other_providers_and_names_test() {
  let active = config("mistral", "deepseek-flash")
  let assert Some(chosen) =
    model_picker.resolve_typed(cat(), active, "openai/gpt-x")
  chosen.name |> should.equal("openrouter")

  // Provider named by its label, any case.
  let assert Some(chosen) =
    model_picker.resolve_typed(cat(), active, "OpenRouter deepseek-pro")
  chosen.name |> should.equal("openrouter")
  chosen.default_model |> should.equal("deepseek-pro")

  model_picker.resolve_typed(cat(), active, "gpt-5") |> should.equal(None)
  model_picker.resolve_typed(cat(), active, "mistral openai/gpt-x")
  |> should.equal(None)
}

pub fn decode_selection_test() {
  model_picker.decode_selection("openrouter|openai/gpt-x", "mistral")
  |> should.equal(catalog.Choice("openrouter", "openai/gpt-x"))
  model_picker.decode_selection("deepseek-pro", "mistral")
  |> should.equal(catalog.Choice("mistral", "deepseek-pro"))
}

pub fn text_choices_lists_every_provider_test() {
  let text =
    model_picker.text_choices(cat(), config("mistral", "deepseek-flash"))
  text
  |> should.equal(
    "Em uso: Mistral / deepseek-flash\n\nDisponíveis:\n"
    <> "Mistral: deepseek-flash, deepseek-pro\n"
    <> "OpenRouter: openai/gpt-x, deepseek-pro\n\n"
    <> "Para trocar: /model <modelo>, ou /model <provedor> <modelo>.",
  )
  string.contains(
    model_picker.unknown_text(cat(), config("mistral", "deepseek-flash"), "x"),
    "Não conheço o modelo \"x\". Nada mudou.",
  )
  |> should.be_true()
}

/// A provider whose label has a space is typed by that label or its key.
pub fn typed_provider_label_with_space_test() {
  let zen = config("opencode_zen", "glm-4.7")
  let cat =
    catalog.Catalog(default: config("mistral", "deepseek-flash"), entries: [
      catalog.Entry(config: config("mistral", "deepseek-flash"), models: [
        "deepseek-flash",
      ]),
      catalog.Entry(config: zen, models: ["glm-4.7", "kimi-k2"]),
    ])
  let active = config("mistral", "deepseek-flash")
  let assert Some(chosen) =
    model_picker.resolve_typed(cat, active, "OpenCode Zen kimi-k2")
  chosen.name |> should.equal("opencode_zen")
  chosen.default_model |> should.equal("kimi-k2")
  let assert Some(chosen) =
    model_picker.resolve_typed(cat, active, "opencode zen  glm-4.7")
  chosen.default_model |> should.equal("glm-4.7")
  let assert Some(chosen) =
    model_picker.resolve_typed(cat, active, "opencode_zen kimi-k2")
  chosen.name |> should.equal("opencode_zen")
  model_picker.resolve_typed(cat, active, "OpenCode Zen") |> should.equal(None)
  model_picker.resolve_typed(cat, active, "OpenCode Zen deepseek-flash")
  |> should.equal(None)
}

/// Bare shortcut words never take an argument: that is conversation.
pub fn shortcut_word_with_text_is_conversation_test() {
  model_picker.parse("modelo de negócio") |> should.equal(None)
  model_picker.parse("models are fun") |> should.equal(None)
}
