//// buscar_conversa: lets an agent search everything its person has said to
//// it, and what it answered, beyond the recent messages it sees.
////
//// The syscall gateway passes the caller's principal; an agent only ever
//// reads its own person's conversations (`agents/<person>/conversations/`):
//// the private chat and the person's side of each group. Matching ignores
//// case and accents; a message matches when it holds every term.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import supernova/agenda/runtime
import supernova/agenda/schedule
import supernova/core/agent_identity
import supernova/core/session/history_store
import supernova/llm/provider

/// Most matches shown; the total is always given.
pub const max_results = 20

/// Longest excerpt of one message, in characters.
pub const max_chars = 600

pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "buscar_conversa",
    description: "Search everything your person and you have said to each other, in every chat, beyond the recent messages you see. Returns the matching messages with date, time and who said it. Use it when asked about something said earlier, or to check what was actually said, instead of guessing. Finding nothing means it was not said, or was forgotten with /esquecer.",
    parameters: [
      provider.string_param(
        "terms",
        "Words to look for. A message matches when it contains all of them; case and accents are ignored.",
        True,
      ),
    ],
  )
}

/// Run a tool call for `principal` with the runtime's data dir and timezone.
pub fn execute(principal: String, args_json: String) -> Result(String, String) {
  case runtime.get() {
    None -> Error("buscar_conversa unavailable: runtime not configured")
    Some(context) ->
      execute_for(
        context.data_dir,
        principal,
        context.offset_minutes,
        args_json,
      )
  }
}

pub fn execute_for(
  data_dir: String,
  principal: String,
  offset: Int,
  args_json: String,
) -> Result(String, String) {
  let decoder = {
    use terms <- decode.field("terms", decode.string)
    decode.success(terms)
  }
  case json.parse(args_json, decoder) {
    Error(_) ->
      Error("Invalid arguments for buscar_conversa: terms is required")
    Ok(raw) ->
      case words(raw) {
        [] -> Error("buscar_conversa needs at least one term")
        terms -> Ok(search(data_dir, principal, terms) |> render(raw, offset))
      }
  }
}

pub type Match {
  Match(chat: String, message: history_store.StoredMessage)
}

pub type Found {
  Found(matches: List(Match), total: Int)
}

/// Every message of the person's conversations holding all `terms`; the
/// most recent `max_results`, oldest first.
pub fn search(
  data_dir: String,
  principal: String,
  terms: List(String),
) -> Found {
  let folded = list.map(terms, fold)
  let dir = history_store.dir(data_dir, principal)
  let all =
    case list_dir(dir) {
      Ok(files) -> files
      Error(_) -> []
    }
    |> list.filter(fn(file) { string.ends_with(file, ".jsonl") })
    |> list.flat_map(fn(file) {
      let chat = chat_label(string.drop_end(file, 6))
      history_store.read_file_messages(dir <> "/" <> file)
      |> list.map(fn(message) { Match(chat: chat, message: message) })
    })
    |> list.filter(fn(match) {
      let content = fold(match.message.content)
      list.all(folded, fn(term) { string.contains(content, term) })
    })
    |> list.sort(fn(a, b) { int.compare(a.message.at, b.message.at) })
  let total = list.length(all)
  Found(matches: list.drop(all, int.max(total - max_results, 0)), total: total)
}

/// "privado" for the one-on-one chat, "grupo" otherwise. A session is
/// `channel:chat:user`; in a private chat the chat is the person.
fn chat_label(encoded_session: String) -> String {
  case string.split(agent_identity.decode_principal(encoded_session), ":") {
    [_, chat, user] if chat == user -> "privado"
    [_, _, _] -> "grupo"
    _ -> "privado"
  }
}

fn render(found: Found, raw: String, offset: Int) -> String {
  case found.total {
    0 ->
      "Nada encontrado para \""
      <> string.trim(raw)
      <> "\" nas conversas guardadas."
    total -> {
      let header = case total > max_results {
        True ->
          int.to_string(total)
          <> " mensagens encontradas; as "
          <> int.to_string(max_results)
          <> " mais recentes, da mais antiga para a mais nova. Use termos mais específicos para as outras."
        False -> int.to_string(total) <> " mensagens encontradas:"
      }
      [header, ..list.map(found.matches, line(_, offset))]
      |> string.join("\n")
    }
  }
}

fn line(match: Match, offset: Int) -> String {
  let when = case match.message.at {
    0 -> "data desconhecida"
    at -> schedule.format_local(at, offset)
  }
  let who = case match.message.role {
    "user" -> "pessoa"
    _ -> "você"
  }
  "["
  <> when
  <> ", "
  <> match.chat
  <> "] "
  <> who
  <> ": "
  <> excerpt(match.message.content)
}

fn excerpt(content: String) -> String {
  let flat = string.replace(content, "\n", " ")
  case string.length(flat) > max_chars {
    True -> string.slice(flat, 0, max_chars) <> "…"
    False -> flat
  }
}

fn words(raw: String) -> List(String) {
  raw
  |> string.replace("\t", " ")
  |> string.replace("\n", " ")
  |> string.split(" ")
  |> list.map(string.trim)
  |> list.filter(fn(word) { word != "" })
}

@external(erlang, "supernova_text_ffi", "fold")
fn fold(text: String) -> String

@external(erlang, "supernova_file_system_ffi", "list_dir")
fn list_dir(path: String) -> Result(List(String), String)
