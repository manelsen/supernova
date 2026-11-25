//// Text made to be heard (PRD-A, A-06), ported from Amélie's screen reader
//// and voice sanitizer (`core/acessibilidade.gleam`): no decorative lines,
//// Markdown tables read as "a — b", decorative repetitions and repeated
//// emojis collapsed. Added for speech: Markdown emphasis, headings and
//// code marks, which a voice would read aloud.

import gleam/list
import gleam/string

pub fn for_speech(text: String) -> String {
  text
  |> drop_decorative_lines
  |> soften_tables
  |> collapse_decorations
  |> collapse_emojis
  |> drop_markdown_marks
  |> string.trim
}

fn drop_decorative_lines(text: String) -> String {
  text
  |> string.split("\n")
  |> list.filter(fn(line) {
    let t = string.trim(line)
    !{
      string.length(t) >= 3
      && list.any(["-", "=", "*", "_", "~"], fn(c) {
        string.replace(t, c, "") == ""
      })
    }
  })
  |> string.join("\n")
}

fn soften_tables(text: String) -> String {
  text
  |> string.split("\n")
  |> list.filter(fn(line) {
    let t = string.trim(line)
    !{
      string.contains(t, "|")
      && string.contains(t, "-")
      && string.replace(t, "|", "")
      |> string.replace("-", "")
      |> string.replace(":", "")
      |> string.trim
      == ""
    }
  })
  |> list.map(fn(line) {
    let t = string.trim(line)
    case string.starts_with(t, "|") && string.ends_with(t, "|") {
      True ->
        t
        |> string.drop_start(1)
        |> string.drop_end(1)
        |> string.split("|")
        |> list.map(string.trim)
        |> string.join(" — ")
      False -> line
    }
  })
  |> string.join("\n")
}

fn collapse_decorations(text: String) -> String {
  text
  |> string.replace("------", "--")
  |> string.replace("-----", "--")
  |> string.replace("----", "--")
  |> string.replace("====", "==")
  |> string.replace("===", "==")
  |> string.replace("******", "")
  |> string.replace("*****", "")
  |> string.replace("****", "")
  |> string.replace("~~~~", "~")
  |> string.replace("~~~", "~")
}

fn collapse_emojis(text: String) -> String {
  ["❤️", "👍", "👏", "🔥", "✨", "⭐", "😂", "🎉"]
  |> list.fold(text, collapse_repeated)
}

fn collapse_repeated(text: String, pattern: String) -> String {
  let three = pattern <> pattern <> pattern
  case string.contains(text, three) {
    True ->
      collapse_repeated(
        string.replace(text, three, pattern <> pattern),
        pattern,
      )
    False -> text
  }
}

/// Emphasis, inline code and heading marks, which a voice reads aloud.
fn drop_markdown_marks(text: String) -> String {
  text
  |> string.replace("**", "")
  |> string.replace("__", "")
  |> string.replace("`", "")
  |> string.split("\n")
  |> list.map(fn(line) {
    case string.trim_start(line) {
      "### " <> rest | "## " <> rest | "# " <> rest -> rest
      _ -> line
    }
  })
  |> string.join("\n")
}
