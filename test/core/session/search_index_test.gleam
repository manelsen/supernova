//// The index `buscar_conversa` searches (PENDENCIAS 0.3): it finds what a
//// read of the whole file finds, follows the file as it grows, and is made
//// again when the file changed otherwise or the index is damaged.

import exception
import gleam/list
import gleam/string
import gleeunit/should
import supernova/core/session/history_store.{HistoryStore, StoredMessage}
import supernova/core/session/search_index
import supernova/tools/buscar_conversa
import test_workspace

const base = 1_795_694_400_000

fn with_dir(body: fn(String) -> a) -> a {
  let dir = test_workspace.create_temp_dir("search_index")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  body(dir)
}

fn say(dir: String, messages: List(#(String, String))) -> Nil {
  let store = HistoryStore(data_dir: dir, limit: 100)
  let stored =
    list.index_map(messages, fn(m, i) {
      StoredMessage(role: m.0, content: m.1, at: base + i)
    })
  let assert Ok(Nil) = history_store.append(store, "sim:dm:ana", stored)
  Nil
}

fn find(dir: String, terms: List(String)) -> buscar_conversa.Found {
  let assert Ok(found) = buscar_conversa.search(dir, "sim:ana", terms)
  found
}

fn shown(found: buscar_conversa.Found) -> List(String) {
  list.flat_map(found.shown, fn(excerpt) {
    list.map(excerpt.lines, fn(line) { line.message.content })
  })
}

fn file(dir: String) -> String {
  let assert Ok([name]) =
    list_dir(history_store.dir(dir, "sim:ana"))
    |> fn(r) {
      case r {
        Ok(names) -> Ok(list.filter(names, string.ends_with(_, ".jsonl")))
        Error(e) -> Error(e)
      }
    }
  history_store.dir(dir, "sim:ana") <> "/" <> name
}

pub fn the_index_finds_what_the_whole_file_holds_test() {
  use dir <- with_dir()
  say(dir, [
    #("user", "o Cardiologista atende na terça"),
    #("assistant", "anotei: cardiologista na terça"),
    #("tool", "cardiologista (resultado de ferramenta)"),
    #("user", "e a Ação\ttem\nduas linhas"),
  ])
  let first = find(dir, ["cardio"])
  first.matches |> should.equal(2)
  // Second search: the index is there and gives the same answer.
  let path = search_index.index_path(file(dir))
  file_exists(path) |> should.equal(Ok(True))
  find(dir, ["cardio"]) |> should.equal(first)
  // Accents, case, a tab and a line break inside a message.
  let acao = find(dir, ["acao", "duas"])
  acao.matches |> should.equal(1)
  shown(acao)
  |> list.contains("e a Ação\ttem\nduas linhas")
  |> should.be_true()
}

pub fn what_is_appended_later_is_found_test() {
  use dir <- with_dir()
  say(dir, [#("user", "primeira mensagem")])
  find(dir, ["orcamento"]).matches |> should.equal(0)
  say(dir, [#("user", "o orçamento chegou")])
  find(dir, ["orcamento"]).matches |> should.equal(1)
  find(dir, ["primeira"]).matches |> should.equal(1)
}

pub fn a_file_changed_in_place_is_indexed_again_test() {
  use dir <- with_dir()
  say(dir, [#("user", "segredo antigo")])
  find(dir, ["antigo"]).matches |> should.equal(1)
  // Same file, other content, longer: an append would not look like this.
  let assert Ok(Nil) =
    write_file(
      file(dir),
      "{\"role\":\"user\",\"content\":\"conteúdo novo e bem mais comprido\",\"at\":1}\n",
    )
  find(dir, ["antigo"]).matches |> should.equal(0)
  find(dir, ["comprido"]).matches |> should.equal(1)
}

pub fn a_damaged_index_is_made_again_test() {
  use dir <- with_dir()
  say(dir, [#("user", "a vacina é sexta")])
  find(dir, ["vacina"]).matches |> should.equal(1)
  let path = search_index.index_path(file(dir))
  let assert Ok(text) = read_file(path)
  let assert Ok(Nil) = write_file(path, string.replace(text, "\t", " "))
  find(dir, ["vacina"]).matches |> should.equal(1)
  let assert Ok(Nil) = write_file(path, "lixo")
  find(dir, ["vacina"]).matches |> should.equal(1)
}

/// A last line without its newline (a write cut short) is found as before,
/// and the index does not keep it: the next write may complete it.
pub fn a_line_cut_short_is_found_and_not_kept_test() {
  use dir <- with_dir()
  say(dir, [#("user", "inteira")])
  let assert Ok(Nil) =
    append_file(
      file(dir),
      "{\"role\":\"user\",\"content\":\"sem quebra no fim\",\"at\":2}",
    )
  find(dir, ["quebra"]).matches |> should.equal(1)
  let assert Ok(text) = read_file(search_index.index_path(file(dir)))
  string.contains(text, "quebra") |> should.be_false()
}

@external(erlang, "supernova_file_system_ffi", "list_dir")
fn list_dir(path: String) -> Result(List(String), String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "append_file")
fn append_file(path: String, content: String) -> Result(Nil, String)
