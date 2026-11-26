//// `/permissoes`: the person's permanent permissions, listed and revoked
//// (PRD-K, K4, K-02). Pure: the command and the text.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/self/aprovacoes.{
  type Grant, type Kind, Login, Overwrite, Send, ShellSite, Spend,
}

pub type Command {
  Listing
  Revoke(Int)
  /// `/permissoes` followed by something it does not take.
  Usage
}

pub fn parse(content: String) -> Option(Command) {
  case
    string.split(string.trim(content), " ") |> list.filter(fn(w) { w != "" })
  {
    [command, ..rest] ->
      case command == "/permissoes" || command == "/permissões" {
        False -> None
        True ->
          case rest {
            [] -> Some(Listing)
            [verb, number] ->
              case verb == "revogar" || verb == "tirar", int.parse(number) {
                True, Ok(id) -> Some(Revoke(id))
                _, _ -> Some(Usage)
              }
            _ -> Some(Usage)
          }
      }
    [] -> None
  }
}

pub const usage =
  "Para ver suas permissões: /permissoes. Para tirar uma: /permissoes revogar N."

pub const only_private =
  "Mande /permissoes no nosso privado: suas permissões são só suas."

/// The permanent permissions, one per line, numbered by their id.
pub fn listing(grants: List(Grant)) -> String {
  case grants {
    [] ->
      "Você não deu nenhuma permissão permanente. Cada ação que precisa de aprovação vai pedir."
    _ ->
      "Suas permissões permanentes:\n"
      <> {
        grants
        |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
        |> list.map(fn(g) { int.to_string(g.id) <> ". " <> describe(g) })
        |> string.join("\n")
      }
      <> "\n\nPara tirar uma: /permissoes revogar N."
  }
}

pub fn revoked(grant: Grant) -> String {
  "Revogada: " <> describe(grant) <> ". Da próxima vez, eu peço de novo."
}

pub fn not_found(id: Int) -> String {
  "Não há permissão " <> int.to_string(id) <> ". Para ver as suas: /permissoes."
}

/// A permission in words.
pub fn describe(grant: Grant) -> String {
  kind_phrase(grant.kind) <> " " <> grant.target
}

fn kind_phrase(kind: Kind) -> String {
  case kind {
    Send -> "Agir no site"
    Login -> "Entrar na sua conta em"
    Overwrite -> "Apagar ou sobrescrever"
    Spend -> "Gastar até US$"
    ShellSite -> "Baixar no shell de"
  }
}
