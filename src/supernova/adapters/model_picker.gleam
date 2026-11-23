//// /model — what people see and type to pick the provider and model.
////
//// Pure: the router owns the choice and where it is kept. Everything offered
//// comes from the catalog (the configured providers and their models), and a
//// pick outside it is refused.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port
import supernova/core/ux
import supernova/llm/catalog
import supernova/llm/provider
import supernova/llm/providers_info

/// Action id of a provider button; the provider name follows.
pub const provider_action_prefix = "picker_provider:"

/// Action id of the model list; the value is `provider|model`.
pub const model_action = "picker_model_select"

pub type Request {
  /// `/model` alone: show what is in use and the choices.
  Show
  /// `/model <modelo>` or `/model <provedor> <modelo>`.
  Pick(String)
}

/// `/model`, `/models` or `/modelo`, with or without an argument; the bare
/// shortcut words ("modelo", "models") alone only show the choices. They
/// never take an argument: "modelo de negócio" is conversation, not a pick.
pub fn parse(content: String) -> Option(Request) {
  case ux.resolve_shortcut(content) {
    Ok(ux.Models) -> Some(Show)
    _ -> {
      let trimmed = string.trim(content)
      case string.split_once(trimmed, " ") {
        Ok(#(command, argument)) ->
          case is_command(command) {
            True ->
              case string.trim(argument) {
                "" -> Some(Show)
                argument -> Some(Pick(argument))
              }
            False -> None
          }
        Error(Nil) ->
          case is_command(trimmed) {
            True -> Some(Show)
            False -> None
          }
      }
    }
  }
}

fn is_command(word: String) -> Bool {
  let word = string.lowercase(word)
  // Telegram appends the bot name in groups: /model@selene_bot
  let word = case string.split_once(word, "@") {
    Ok(#(head, _)) -> head
    Error(Nil) -> word
  }
  word == "/model" || word == "/models" || word == "/modelo"
}

/// The pair a typed argument names. A bare model is looked for first at the
/// provider in use, then at the others; `<provedor> <modelo>` names both.
pub fn resolve_typed(
  cat: catalog.Catalog,
  active: provider.ProviderConfig,
  argument: String,
) -> Option(provider.ProviderConfig) {
  let argument = string.trim(argument)
  let bare = fn(model) {
    let providers = [
      active.name,
      ..list.filter(catalog.providers(cat), fn(name) { name != active.name })
    ]
    list.find_map(providers, fn(provider_name) {
      case catalog.resolve(cat, catalog.Choice(provider_name, model)) {
        Some(config) -> Ok(config)
        None -> Error(Nil)
      }
    })
    |> option.from_result
  }
  case bare(argument) {
    Some(config) -> Some(config)
    None ->
      // `<provedor> <modelo>`: the provider by its key or its label, which
      // may have spaces ("OpenCode Zen").
      catalog.providers(cat)
      |> list.find_map(fn(provider_name) {
        provider_names(provider_name)
        |> list.find_map(fn(name) {
          case strip_word_prefix(argument, name) {
            Ok(model) ->
              catalog.resolve(cat, catalog.Choice(provider_name, model))
              |> option.to_result(Nil)
            Error(Nil) -> Error(Nil)
          }
        })
      })
      |> option.from_result
  }
}

/// How a provider may be typed: its key (`opencode_zen`) and its label
/// (`OpenCode Zen`).
fn provider_names(provider_name: String) -> List(String) {
  case providers_info.get_provider(provider_name) {
    Some(info) -> [provider_name, info.label]
    None -> [provider_name]
  }
}

/// The rest of `text` after `word` and a space, ignoring case.
fn strip_word_prefix(text: String, word: String) -> Result(String, Nil) {
  let prefix = string.lowercase(word) <> " "
  case string.starts_with(string.lowercase(text), prefix) {
    True ->
      case string.trim(string.drop_start(text, string.length(prefix))) {
        "" -> Error(Nil)
        rest -> Ok(rest)
      }
    False -> Error(Nil)
  }
}

/// A selection value from a button or list: `provider|model`. Without the
/// provider, the one in use.
pub fn decode_selection(
  value: String,
  active_provider: String,
) -> catalog.Choice {
  case string.split_once(value, "|") {
    Ok(#(provider_name, model)) -> catalog.Choice(provider_name, model)
    Error(Nil) -> catalog.Choice(active_provider, value)
  }
}

pub fn parse_provider_action(action_id: String) -> Option(String) {
  case string.starts_with(action_id, provider_action_prefix) {
    True ->
      Some(string.drop_start(action_id, string.length(provider_action_prefix)))
    False -> None
  }
}

pub fn display_name(provider_name: String) -> String {
  case providers_info.get_provider(provider_name) {
    Some(info) -> info.label
    None ->
      case provider_name {
        "mock" -> "Mock"
        other -> other
      }
  }
}

fn in_use(active: provider.ProviderConfig) -> String {
  display_name(active.name) <> " / " <> active.default_model
}

/// The first line of the /model answer.
pub fn intro(active: provider.ProviderConfig) -> String {
  "Em uso: " <> in_use(active) <> "\nEscolha abaixo."
}

/// Buttons for the providers (only when there is more than one) and the
/// list of the active provider's models.
pub fn picker(
  cat: catalog.Catalog,
  active: provider.ProviderConfig,
) -> port.ChannelInteractiveReply {
  let provider_blocks = case catalog.providers(cat) {
    [_, _, ..] as names -> [
      port.buttons_block(
        list.map(names, fn(name) {
          port.button(
            label: display_name(name),
            action_id: provider_action_prefix <> name,
            style: case name == active.name {
              True -> port.ButtonSuccess
              False -> port.ButtonPrimary
            },
          )
        }),
      ),
    ]
    _ -> []
  }
  let options =
    catalog.models(cat, active.name)
    |> list.map(fn(model) {
      port.select_option(
        label: case model == active.default_model {
          True -> "✓ " <> model
          False -> model
        },
        value: active.name <> "|" <> model,
      )
    })
  port.interactive_reply(
    list.flatten([
      [port.text_block("Provedor: " <> display_name(active.name))],
      provider_blocks,
      [
        port.select_block(
          action_id: model_action,
          placeholder: Some("Escolha o modelo"),
          options: options,
        ),
      ],
    ]),
  )
}

/// For channels without buttons: every choice, and how to type it.
pub fn text_choices(
  cat: catalog.Catalog,
  active: provider.ProviderConfig,
) -> String {
  let lines =
    cat.entries
    |> list.map(fn(entry) {
      display_name(entry.config.name) <> ": " <> string.join(entry.models, ", ")
    })
  "Em uso: "
  <> in_use(active)
  <> "\n\nDisponíveis:\n"
  <> string.join(lines, "\n")
  <> "\n\nPara trocar: /model <modelo>, ou /model <provedor> <modelo>."
}

pub fn chosen_text(chosen: provider.ProviderConfig) -> String {
  "Modelo trocado para "
  <> in_use(chosen)
  <> ". Vale para as próximas mensagens, também depois de reiniciar."
}

pub fn unchanged_text(chosen: provider.ProviderConfig) -> String {
  "Já está em uso: " <> in_use(chosen) <> "."
}

pub fn unknown_text(
  cat: catalog.Catalog,
  active: provider.ProviderConfig,
  argument: String,
) -> String {
  "Não conheço o modelo \""
  <> argument
  <> "\". Nada mudou.\n\n"
  <> text_choices(cat, active)
}

pub fn unavailable_text(active: provider.ProviderConfig) -> String {
  "Essa opção não está mais disponível. Continua em uso: "
  <> in_use(active)
  <> "."
}

/// What /status says about the model.
pub fn status_lines(active: provider.ProviderConfig) -> String {
  "Provedor: "
  <> display_name(active.name)
  <> "\nModelo: "
  <> active.default_model
}
