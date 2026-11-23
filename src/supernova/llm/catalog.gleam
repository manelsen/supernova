//// The models people may pick with /model.
////
//// Built once at boot from the configured providers: each usable provider
//// (it has a key, or needs none) with its own key and address, its `model`
//// first and then its `models`. A choice outside the catalog is refused, so
//// a forged button can never reach a provider or model nobody configured.

import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/config
import supernova/llm/provider

pub type Entry {
  /// `config.default_model` is the provider's configured model.
  Entry(config: provider.ProviderConfig, models: List(String))
}

pub type Catalog {
  Catalog(default: provider.ProviderConfig, entries: List(Entry))
}

/// The provider and model in use, as kept between restarts.
pub type Choice {
  Choice(provider: String, model: String)
}

/// The runtime form of one configured provider.
pub fn runtime_config(
  provider_config: config.ProviderConfig,
) -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: config.provider_runtime_name(provider_config.provider),
    api_key: provider_config.api_key,
    base_url: provider_config.base_url,
    default_model: case provider_config.model {
      Some(model) -> model
      None -> config.provider_default_model(provider_config.provider)
    },
  )
}

/// Every usable provider, by configured name. The default (the one every
/// agent starts with) comes first; two entries of the same kind keep the
/// first.
pub fn from_config(
  cfg: config.Config,
  default: provider.ProviderConfig,
) -> Catalog {
  let entries =
    cfg.providers
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.filter(fn(pair) { config.provider_usable(pair.1) })
    |> list.map(fn(pair) {
      let runtime = runtime_config(pair.1)
      Entry(
        config: runtime,
        models: unique([runtime.default_model, ..pair.1.models]),
      )
    })
  new(default, entries)
}

/// A catalog holding only the default provider and model.
pub fn single(default: provider.ProviderConfig) -> Catalog {
  new(default, [])
}

fn new(default: provider.ProviderConfig, entries: List(Entry)) -> Catalog {
  let default_entry = case
    list.find(entries, fn(e) { e.config.name == default.name })
  {
    Ok(entry) ->
      Entry(..entry, models: unique([default.default_model, ..entry.models]))
    Error(Nil) -> Entry(config: default, models: [default.default_model])
  }
  let others =
    entries
    |> list.filter(fn(e) { e.config.name != default.name })
    |> list.fold([], fn(kept, entry) {
      case list.any(kept, fn(k: Entry) { k.config.name == entry.config.name }) {
        True -> kept
        False -> [entry, ..kept]
      }
    })
    |> list.reverse
  Catalog(default: default, entries: [default_entry, ..others])
}

/// Trimmed, without blanks or repeats, in order.
fn unique(items: List(String)) -> List(String) {
  items
  |> list.map(string.trim)
  |> list.filter(fn(item) { item != "" })
  |> list.fold([], fn(kept, item) {
    case list.contains(kept, item) {
      True -> kept
      False -> [item, ..kept]
    }
  })
  |> list.reverse
}

pub fn providers(catalog: Catalog) -> List(String) {
  list.map(catalog.entries, fn(entry) { entry.config.name })
}

/// The models offered for a provider; empty when it is not in the catalog.
pub fn models(catalog: Catalog, provider_name: String) -> List(String) {
  case entry(catalog, provider_name) {
    Some(found) -> found.models
    None -> []
  }
}

/// Every provider and model pair, for declaring metric series at boot.
pub fn choices(catalog: Catalog) -> List(Choice) {
  list.flat_map(catalog.entries, fn(entry) {
    list.map(entry.models, fn(model) { Choice(entry.config.name, model) })
  })
}

/// The provider's configuration with its configured model.
pub fn provider_config(
  catalog: Catalog,
  provider_name: String,
) -> Option(provider.ProviderConfig) {
  case entry(catalog, provider_name) {
    Some(found) -> Some(found.config)
    None -> None
  }
}

/// The configuration to call `model` at `provider_name`, only when the pair
/// is in the catalog.
pub fn resolve(
  catalog: Catalog,
  choice: Choice,
) -> Option(provider.ProviderConfig) {
  case entry(catalog, choice.provider) {
    Some(found) ->
      case list.contains(found.models, choice.model) {
        True ->
          Some(
            provider.ProviderConfig(..found.config, default_model: choice.model),
          )
        False -> None
      }
    None -> None
  }
}

fn entry(catalog: Catalog, provider_name: String) -> Option(Entry) {
  case list.find(catalog.entries, fn(e) { e.config.name == provider_name }) {
    Ok(found) -> Some(found)
    Error(Nil) -> None
  }
}

// ============================================================================
// Global registration
// ============================================================================

const global_key = "supernova_global_llm_catalog"

pub fn set_global(catalog: Catalog) -> Nil {
  global_put(global_key, catalog)
}

/// The catalog published at boot, or one holding only `default` when none
/// was, or when it was built for another default (tests, embedded routers).
pub fn current(default: provider.ProviderConfig) -> Catalog {
  case global_lookup(global_key) {
    Ok(catalog) ->
      case catalog.default == default {
        True -> catalog
        False -> single(default)
      }
    Error(Nil) -> single(default)
  }
}

pub fn clear_global() -> Nil {
  global_erase(global_key)
}

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: any) -> Nil

@external(erlang, "supernova_global_ffi", "global_lookup")
fn global_lookup(key: String) -> Result(Catalog, Nil)

@external(erlang, "supernova_global_ffi", "global_erase")
fn global_erase(key: String) -> Nil
