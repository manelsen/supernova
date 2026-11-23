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
import gleam/string
import supernova/agenda/runtime
import supernova/agenda/schedule
import supernova/core/session/history_store
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

pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "buscar_conversa",
    description: "Search everything your person and you have said to each other, in every chat, beyond the recent messages you see. Returns excerpts: each matching message (marked ») with the message before it and the two after it, with date, time and who said it, since the answer is often in the next message. Use it when asked about something said earlier, or to check what was actually said, instead of guessing. If the first words find nothing useful, try others. Finding nothing means it was not said, or was forgotten with /esquecer.",
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
/// its neighbours. Each file is read whole and cut to its excerpts before
/// the next, so only excerpts accumulate; a call still reads the person's
/// whole history, which is never pruned. No conversations yet is no match;
/// a directory or file that cannot be read is an error, never "not said".
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
      history_store.read_file_strict(dir <> "/" <> file)
      |> result.map_error(unreadable)
      |> result.map(fn(messages) {
        excerpts(messages, fn(message) {
          let content = fold(message.content)
          list.all(folded, fn(term) { string.contains(content, term) })
        })
      })
    }),
  )
  let all =
    list.flatten(per_file)
    |> list.sort(fn(a, b) { int.compare(first_at(a), first_at(b)) })
  let count = list.length(all)
  let recent = list.drop(all, int.max(count - max_excerpts, 0))
  let shown = cap_lines(recent)
  Found(
    shown: shown,
    matches: all
      |> list.map(fn(excerpt) { list.count(excerpt.lines, fn(l) { l.hit }) })
      |> int.sum,
    excerpts: count,
    trimmed: count > max_excerpts || line_count(shown) < line_count(recent),
  )
}

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

fn first_at(excerpt: Excerpt) -> Int {
  case excerpt.lines {
    [first, ..] -> first.message.at
    [] -> 0
  }
}

/// The excerpts of one conversation: each match widened by `before` and
/// `after` messages, overlapping windows merged.
pub fn excerpts(
  messages: List(history_store.StoredMessage),
  matches: fn(history_store.StoredMessage) -> Bool,
) -> List(Excerpt) {
  let indexed = list.index_map(messages, fn(message, i) { #(i, message) })
  let hits =
    indexed
    |> list.filter(fn(pair) { matches(pair.1) })
    |> list.map(fn(pair) { pair.0 })
  let windows =
    list.fold(hits, [], fn(acc, i) {
      let start = int.max(i - before, 0)
      let stop = i + after
      case acc {
        [#(s, e), ..rest] if start <= e + 1 -> [#(s, int.max(e, stop)), ..rest]
        _ -> [#(start, stop), ..acc]
      }
    })
    |> list.reverse
  list.map(windows, fn(window) {
    let #(start, stop) = window
    Excerpt(
      lines: indexed
      |> list.filter(fn(pair) { pair.0 >= start && pair.0 <= stop })
      |> list.map(fn(pair) {
        Line(message: pair.1, hit: list.contains(hits, pair.0))
      }),
    )
  })
}

fn render(found: Found, raw: String, offset: Int) -> String {
  case found.matches {
    0 ->
      "Nada encontrado para \""
      <> string.trim(raw)
      <> "\" nas conversas guardadas."
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
