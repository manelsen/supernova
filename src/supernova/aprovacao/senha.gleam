//// `/senha` (PRD-K, K12): how a person gives a password to the vault,
//// answered by the code before the model, in private, by text only.
////
//// - `/senha` lists the sites with a password (never the passwords);
//// - `/senha <site> <usuário> <senha>` keeps one;
//// - `/senha apagar <site>` deletes one.
////
//// `redact` takes the password out of a `/senha` message: what is kept on
//// disk (the inbox) never has it (K-I3).

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Command {
  Listar
  Guardar(site: String, usuario: String, senha: String)
  Apagar(site: String)
  Uso
}

fn is_command(word: String) -> Bool {
  word == "/senha" || word == "/senhas"
}

pub fn parse(content: String) -> Option(Command) {
  let text = string.trim(content)
  case string.split_once(text, " ") {
    Error(Nil) ->
      case is_command(text) {
        True -> Some(Listar)
        False -> None
      }
    Ok(#(head, rest)) ->
      case is_command(head) {
        False -> None
        True -> {
          let rest = string.trim_start(rest)
          case string.split_once(rest, " ") {
            Ok(#("apagar", site)) -> Some(Apagar(site_of(site)))
            Ok(#(site, more)) ->
              case string.split_once(string.trim_start(more), " ") {
                Ok(#(usuario, senha)) ->
                  case string.trim(senha) {
                    "" -> Some(Uso)
                    // The password is kept as typed, inner spaces included.
                    _ -> Some(Guardar(site_of(site), usuario, senha))
                  }
                Error(Nil) -> Some(Uso)
              }
            Error(Nil) -> Some(Uso)
          }
        }
      }
  }
}

/// A site as typed (`https://Gov.br/`) as the vault keys it (`gov.br`).
pub fn site_of(text: String) -> String {
  let text = string.lowercase(string.trim(text))
  let text = case string.split_once(text, "://") {
    Ok(#(_, rest)) -> rest
    Error(Nil) -> text
  }
  text
  |> string.split("/")
  |> list.first
  |> option.from_result
  |> option.unwrap("")
}

/// The message as it may be kept: a `/senha` with a password keeps only the
/// command, the site and the user name.
pub fn redact(content: String) -> String {
  case parse(content) {
    Some(Guardar(site, usuario, _)) ->
      "/senha " <> site <> " " <> usuario <> " [senha omitida]"
    Some(_) -> content
    None ->
      case string.starts_with(string.trim(content), "/senha") {
        True -> "/senha [omitido]"
        False -> content
      }
  }
}

/// A voice note that says "/senha" or "barra senha": refused, explained.
pub fn spoken(content: String) -> Bool {
  case string.split_once(string.trim(content), "]\n") {
    Ok(#(heading, text)) -> {
      let voice =
        string.starts_with(heading, "[mensagem de voz")
        || string.starts_with(heading, "[áudio")
      let said = string.lowercase(string.trim(text))
      voice
      && {
        string.starts_with(said, "/senha")
        || string.starts_with(said, "barra senha")
        || string.starts_with(said, "senha ")
      }
    }
    Error(Nil) -> False
  }
}

pub const voice_refused =
  "Por segurança, senha só por texto: uma mensagem de voz passa por um serviço de transcrição de fora. Se quiser, use o ditado do seu celular, que vira texto, e mande: /senha site usuário senha. Depois apague a mensagem de voz."

pub const usage =
  "Para guardar uma senha: /senha site usuário senha (por exemplo, /senha gov.br 12345678900 minhasenha). Para ver os sites: /senha. Para apagar: /senha apagar site."

pub const only_private =
  "Senha só no nosso privado. Apague esta mensagem do grupo agora."

pub const no_vault =
  "O cofre de senhas não está ligado nesta instalação. Nada foi guardado; apague a mensagem com a senha."

pub fn kept(site: String, usuario: String, deleted: Bool) -> String {
  "Guardei a senha de "
  <> site
  <> " (usuário "
  <> usuario
  <> "), cifrada. Ela não vai para a agente: só é usada para entrar no site, e eu peço sua confirmação antes."
  <> case deleted {
    True -> " Apaguei a sua mensagem com a senha."
    False -> " Apague agora a sua mensagem com a senha deste chat."
  }
}

pub fn listing(sites: List(#(String, String))) -> String {
  case sites {
    [] -> "Você não guardou nenhuma senha. " <> usage
    _ ->
      "Senhas guardadas (só os sites, nunca as senhas):\n"
      <> {
        sites
        |> list.map(fn(pair) { pair.0 <> ", usuário " <> pair.1 })
        |> string.join("\n")
      }
      <> "\n\nPara apagar: /senha apagar site."
  }
}

pub fn deleted(site: String, found: Bool) -> String {
  case found {
    True -> "Apaguei a senha de " <> site <> "."
    False -> "Não há senha guardada para " <> site <> "."
  }
}
