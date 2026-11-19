//// Single-pass placeholder rendering for maintainer prompts.
////
//// Values are inserted as-is: placeholder-like text inside a value (a trait
//// description, a journal line written by a person) is never substituted.

import gleam/list
import gleam/string

/// Replace every `{{name}}` in `template` with its value, scanning the
/// template once. Unknown placeholders are kept verbatim.
pub fn render(template: String, values: List(#(String, String))) -> String {
  render_loop(template, values, [])
}

fn render_loop(
  rest: String,
  values: List(#(String, String)),
  acc: List(String),
) -> String {
  case string.split_once(rest, "{{") {
    Error(_) -> finish([rest, ..acc])
    Ok(#(before, after)) ->
      case string.split_once(after, "}}") {
        Error(_) -> finish([rest, ..acc])
        Ok(#(name, tail)) ->
          case list.key_find(values, name) {
            Ok(value) -> render_loop(tail, values, [value, before, ..acc])
            Error(_) ->
              render_loop(tail, values, ["{{" <> name <> "}}", before, ..acc])
          }
      }
  }
}

fn finish(parts: List(String)) -> String {
  parts |> list.reverse |> string.concat
}
