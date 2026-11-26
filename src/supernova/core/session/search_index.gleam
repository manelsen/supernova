//// What `buscar_conversa` reads instead of decoding a whole conversation
//// (PENDENCIAS 0.3, "Índice para a buscar_conversa").
////
//// Next to each conversation file (`<session>.jsonl`) lives
//// `<session>.busca`: one line per message of the conversation (what the
//// person and the agent said, not tool calls), with its place in the file
//// and its text already folded (case and accents gone, as `fold` does).
//// A search matches against the folded texts and decodes only the messages
//// it shows. Decoding the JSON was nearly all the time of a search: 1.2 s of
//// 1.5 s over 20 thousand messages.
////
//// The index follows the file, which is only ever appended to: a search
//// indexes what was appended since, and a file that changed otherwise (its
//// indexed part no longer has the same checksum) is indexed again from the
//// start. It lives in the conversations directory, so `/esquecer` deletes
//// it with the conversations. Failing to write it only costs time.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import supernova/core/session/history_store

/// One message of a conversation: where its line is in the file, and its
/// text folded, with line breaks and tabs turned into spaces.
pub type Entry {
  Entry(offset: Int, length: Int, folded: String)
}

/// A conversation ready to search: its bytes and its messages, in order.
pub type Indexed {
  Indexed(bytes: BitArray, entries: List(Entry))
}

const header = "busca 1"

/// The index file of a conversation file.
pub fn index_path(conversation: String) -> String {
  case string.ends_with(conversation, ".jsonl") {
    True -> string.drop_end(conversation, 6) <> ".busca"
    False -> conversation <> ".busca"
  }
}

/// The conversation in `path`, indexed. A missing file is an empty
/// conversation; any other failure to read it is an error.
pub fn load(path: String) -> Result(Indexed, String) {
  use bytes <- result.try(case read_bits(path) {
    Ok(bytes) -> Ok(bytes)
    Error(reason) ->
      case history_store.is_missing(reason) {
        True -> Ok(<<>>)
        False -> Error(reason)
      }
  })
  let stored = read_index(index_path(path), bytes)
  let #(covered, kept) = case stored {
    Ok(#(covered, entries)) -> #(covered, entries)
    Error(Nil) -> #(0, [])
  }
  let #(lines, end) = complete_lines(bytes, covered)
  let added = list.filter_map(lines, entry_of)
  let entries = list.append(kept, added)
  case stored, end == covered {
    Ok(_), True -> Nil
    _, _ -> {
      let _ = write_index(index_path(path), bytes, end, entries)
      Nil
    }
  }
  // A last line without its newline (a write cut short) is searched as the
  // whole-file read did, but not kept: it may still grow.
  let tail = case bit_array.byte_size(bytes) > end {
    True ->
      bit_array.slice(bytes, end, bit_array.byte_size(bytes) - end)
      |> result.try(fn(rest) { entry_of(#(end, rest)) })
      |> result.map(fn(entry) { [entry] })
      |> result.unwrap([])
    False -> []
  }
  Ok(Indexed(bytes: bytes, entries: list.append(entries, tail)))
}

/// The message an entry stands for.
pub fn message(
  indexed: Indexed,
  entry: Entry,
) -> Result(history_store.StoredMessage, Nil) {
  use line <- result.try(bit_array.slice(
    indexed.bytes,
    entry.offset,
    entry.length,
  ))
  use text <- result.try(bit_array.to_string(line))
  history_store.decode_line(text)
}

fn entry_of(line: #(Int, BitArray)) -> Result(Entry, Nil) {
  let #(offset, bytes) = line
  use text <- result.try(bit_array.to_string(bytes))
  use stored <- result.try(history_store.decode_line(text))
  case stored.role {
    "user" | "assistant" ->
      Ok(Entry(
        offset: offset,
        length: bit_array.byte_size(bytes),
        folded: fold(stored.content)
          |> string.replace("\n", " ")
          |> string.replace("\t", " "),
      ))
    _ -> Error(Nil)
  }
}

/// The index of a file, if it still describes it: the header names how many
/// bytes it covers and their checksum.
fn read_index(
  path: String,
  bytes: BitArray,
) -> Result(#(Int, List(Entry)), Nil) {
  use text <- result.try(read_file(path) |> result.replace_error(Nil))
  use #(first, rest) <- result.try(string.split_once(text, "\n"))
  use #(covered, sum) <- result.try(case string.split(first, " ") {
    ["busca", "1", covered, sum] ->
      case int.parse(covered), int.parse(sum) {
        Ok(covered), Ok(sum) -> Ok(#(covered, sum))
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  })
  case checksum(bytes, covered) == sum {
    False -> Error(Nil)
    True ->
      parse_entries(rest)
      |> result.map(fn(entries) { #(covered, entries) })
  }
}

fn write_index(
  path: String,
  bytes: BitArray,
  covered: Int,
  entries: List(Entry),
) -> Result(Nil, String) {
  let lines =
    list.map(entries, fn(entry) {
      int.to_string(entry.offset)
      <> "\t"
      <> int.to_string(entry.length)
      <> "\t"
      <> entry.folded
      <> "\n"
    })
  write_file_atomic(
    path,
    string.concat([
      header,
      " ",
      int.to_string(covered),
      " ",
      int.to_string(checksum(bytes, covered)),
      "\n",
      ..lines
    ]),
  )
}

/// Case folded and without accents; invalid UTF-8 comes back unchanged.
@external(erlang, "supernova_text_ffi", "fold")
pub fn fold(text: String) -> String

@external(erlang, "supernova_search_index_ffi", "complete_lines")
fn complete_lines(bytes: BitArray, from: Int) -> #(List(#(Int, BitArray)), Int)

@external(erlang, "supernova_search_index_ffi", "parse_entries")
fn parse_entries(body: String) -> Result(List(Entry), Nil)

@external(erlang, "supernova_search_index_ffi", "checksum")
fn checksum(bytes: BitArray, upto: Int) -> Int

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_bits(path: String) -> Result(BitArray, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file_atomic")
fn write_file_atomic(path: String, content: String) -> Result(Nil, String)
