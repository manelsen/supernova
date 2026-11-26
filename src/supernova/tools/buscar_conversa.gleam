//// buscar_conversa: lets an agent search everything its person has said to
//// it, and what it answered, beyond the recent messages it sees.
////
//// The syscall gateway passes the caller's principal; an agent only ever
//// reads its own person's conversations (`agents/<person>/conversations/`):
//// the private chat and the person's side of each group. Matching ignores
//// case and accents; a message matches when it holds every term.
////
//// Each match comes with the messages around it: what was said right after
//// a word is often the answer ("o cardiologista... guarda o nome dele? é o
//// dr. Fulano"), and a match alone would hide it.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import supernova/agenda/runtime
import supernova/agenda/schedule
import supernova/core/session/history_store
import supernova/core/session/search_index
import supernova/llm/provider

/// Most excerpts shown, the most recent; the totals are always given.
pub const max_excerpts = 10

/// Messages shown before and after each match.
pub const before = 1

pub const after = 2

/// Most lines shown in all; past it, the oldest excerpts go first, and an
/// excerpt longer than this keeps its last lines.
pub const max_lines = 60

/// Longest text of one message, in characters.
pub const max_chars = 600

/// Closes an empty result. The tone belongs in the result, where the agent
/// reads it at the moment of answering: told only in the description, the
/// agent still answered "you never told me" about things said in other
/// words (docs/relatorios/BUSCA-bancada.md).
pub const not_found_hint =
  "Pode ter sido dito com outras palavras: tente outras. Se ainda assim não achar, diga que não se lembra, não que nunca foi dito."

/// Closes a result with excerpts: what was found may be about something
/// else (the neighbour's dog, when asked about hers).
pub const found_hint =
  "Se nenhum trecho acima responde à pergunta, diga que não se lembra; não diga que nunca foi dito."

pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "buscar_conversa",
    description: "Search everything your person and you have said to each other, in every chat, beyond the recent messages you see. Returns excerpts: each matching message (marked ») with the message before it and the two after it, with date, time and who said it, since the answer is often in the next message. Use it when asked about something said earlier, or to check what was actually said, instead of guessing. If the first words find nothing useful, try others: synonyms, a shorter word, the singular. Finding nothing only means these words are not there; it may have been said in other words. So if it is still not found, say you don't remember it, not that it was never said. What was forgotten with /esquecer is gone.",
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
        terms ->
          search(data_dir, principal, terms)
          |> result.map(render(_, raw, offset))
      }
  }
}

/// One message of an excerpt; `hit` when it holds every term.
pub type Line {
  Line(message: history_store.StoredMessage, hit: Bool)
}

/// Consecutive messages of one conversation around one or more matches.
pub type Excerpt {
  Excerpt(lines: List(Line))
}

pub type Found {
  /// The most recent excerpts that fit, oldest first; `matches` and
  /// `excerpts` count everything found; `trimmed` when some was left out.
  Found(shown: List(Excerpt), matches: Int, excerpts: Int, trimmed: Bool)
}

/// Every message of the person's conversations holding all `terms`, with
/// its neighbours. A call matches against each conversation's index
/// (`search_index`: the folded text of every message, kept next to the
/// file) and decodes only the messages it shows; excerpts are cut by
/// position, never by scanning. No conversations yet is no match; a
/// directory or file that cannot be read is an error, never "not said".
pub fn search(
  data_dir: String,
  principal: String,
  terms: List(String),
) -> Result(Found, String) {
  let folded = list.map(terms, fold)
  let dir = history_store.dir(data_dir, principal)
  let unreadable = fn(reason) {
    "buscar_conversa could not read the conversations: " <> reason
  }
  use files <- result.try(case list_dir(dir) {
    Ok(files) -> Ok(files)
    Error(reason) ->
      case history_store.is_missing(reason) {
        True -> Ok([])
        False -> Error(unreadable(reason))
      }
  })
  use per_file <- result.map(
    files
    |> list.filter(fn(file) { string.ends_with(file, ".jsonl") })
    |> list.try_map(fn(file) {
      search_index.load(dir <> "/" <> file)
      |> result.map_error(unreadable)
      |> result.map(file_windows(_, folded))
    }),
  )
  let windows =
    list.flatten(per_file)
    |> list.sort(fn(a, b) { int.compare(a.at, b.at) })
  let count = list.length(windows)
  let recent =
    list.drop(windows, int.max(count - max_excerpts, 0))
    |> list.map(window_excerpt)
  let shown = cap_lines(recent)
  Found(
    shown: shown,
    matches: windows |> list.map(fn(w) { set.size(w.hits) }) |> int.sum,
    excerpts: count,
    trimmed: count > max_excerpts || line_count(shown) < line_count(recent),
  )
}

/// Consecutive positions of one conversation around matches.
type Window {
  Window(said: Said, start: Int, stop: Int, hits: Set(Int), at: Int)
}

/// One conversation's said messages (not the tool calls kept in between),
/// by position, decoded when shown.
type Said {
  Said(indexed: search_index.Indexed, entries: Entries)
}

type Entries

fn file_windows(
  indexed: search_index.Indexed,
  folded_terms: List(String),
) -> List(Window) {
  let size = list.length(indexed.entries)
  let by_position = Said(indexed, to_entries(indexed.entries))
  indexed.entries
  |> list.index_map(fn(entry, position) { #(position, entry) })
  |> list.filter_map(fn(item) {
    case list.all(folded_terms, string.contains({ item.1 }.folded, _)) {
      True -> Ok(item.0)
      False -> Error(Nil)
    }
  })
  |> list.fold([], fn(acc, position) {
    let start = int.max(position - before, 0)
    let stop = int.min(position + after, size - 1)
    case acc {
      [#(s, e, inside), ..rest] if start <= e + 1 -> [
        #(s, int.max(e, stop), [position, ..inside]),
        ..rest
      ]
      _ -> [#(start, stop, [position]), ..acc]
    }
  })
  |> list.reverse
  |> list.map(fn(window) {
    let #(start, stop, inside) = window
    Window(
      said: by_position,
      start: start,
      stop: stop,
      hits: set.from_list(inside),
      at: { message_at(by_position, start) }.at,
    )
  })
}

fn window_excerpt(window: Window) -> Excerpt {
  Excerpt(
    lines: positions(window.start, window.stop)
    |> list.map(fn(position) {
      Line(
        message: message_at(window.said, position),
        hit: set.contains(window.hits, position),
      )
    }),
  )
}

fn positions(from: Int, to: Int) -> List(Int) {
  case to < from {
    True -> []
    False -> [from, ..positions(from + 1, to)]
  }
}

@external(erlang, "erlang", "list_to_tuple")
fn to_entries(entries: List(search_index.Entry)) -> Entries

/// 0-based. An entry always decodes: it was made from that same line.
fn message_at(said: Said, position: Int) -> history_store.StoredMessage {
  case search_index.message(said.indexed, element(position + 1, said.entries)) {
    Ok(message) -> message
    Error(Nil) -> history_store.StoredMessage(role: "user", content: "", at: 0)
  }
}

@external(erlang, "erlang", "element")
fn element(index: Int, entries: Entries) -> search_index.Entry

fn line_count(excerpts: List(Excerpt)) -> Int {
  excerpts |> list.map(fn(excerpt) { list.length(excerpt.lines) }) |> int.sum
}

/// The most recent excerpts that fit in `max_lines`, oldest first.
fn cap_lines(excerpts: List(Excerpt)) -> List(Excerpt) {
  list.reverse(excerpts)
  |> list.fold(#([], 0), fn(acc, excerpt) {
    let #(kept, used) = acc
    let room = max_lines - used
    let size = list.length(excerpt.lines)
    case room, size <= room {
      0, _ -> acc
      _, True -> #([excerpt, ..kept], used + size)
      _, False -> #(
        [Excerpt(lines: list.drop(excerpt.lines, size - room)), ..kept],
        max_lines,
      )
    }
  })
  |> fn(acc) { acc.0 }
}

fn render(found: Found, raw: String, offset: Int) -> String {
  case found.matches {
    0 ->
      "Nada encontrado para \""
      <> string.trim(raw)
      <> "\" nas conversas guardadas. "
      <> not_found_hint
    matches -> {
      let header =
        int.to_string(matches)
        <> plural(matches, " mensagem encontrada", " mensagens encontradas")
        <> ", em "
        <> int.to_string(found.excerpts)
        <> plural(found.excerpts, " trecho", " trechos")
        <> case found.trimmed {
          True ->
            "; abaixo, só os mais recentes. Use termos mais específicos para ver os outros."
          False -> ":"
        }
      [header, ..list.map(found.shown, render_excerpt(_, offset))]
      |> list.append([found_hint])
      |> string.join("\n\n")
    }
  }
}

fn plural(n: Int, one: String, many: String) -> String {
  case n {
    1 -> one
    _ -> many
  }
}

fn render_excerpt(excerpt: Excerpt, offset: Int) -> String {
  excerpt.lines
  |> list.map(fn(line) {
    let when = case line.message.at {
      0 -> "data desconhecida"
      at -> schedule.format_local(at, offset)
    }
    let who = case line.message.role {
      "user" -> "pessoa"
      _ -> "você"
    }
    let mark = case line.hit {
      True -> "» "
      False -> "  "
    }
    mark <> "[" <> when <> "] " <> who <> ": " <> text(line.message.content)
  })
  |> string.join("\n")
}

fn text(content: String) -> String {
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

/// Case folded and without accents; invalid UTF-8 comes back unchanged.
@external(erlang, "supernova_text_ffi", "fold")
pub fn fold(text: String) -> String

@external(erlang, "supernova_file_system_ffi", "list_dir")
fn list_dir(path: String) -> Result(List(String), String)
