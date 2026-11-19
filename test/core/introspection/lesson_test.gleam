import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import supernova/core/introspection/lesson

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

fn unique_workspace(prefix: String) -> String {
  "/tmp/supernova-lesson-" <> prefix <> "-" <> int.to_string(now_ms())
}

pub fn append_and_load_recent_orders_by_created_at_test() {
  let workspace = unique_workspace("recent")
  let first =
    lesson.make_success_lesson(
      "session-1",
      "Validar argumentos antes de executar shell.",
      "Comando de build",
    )
  let second =
    lesson.make_error_lesson(
      "session-1",
      "Falha ao chamar ferramenta de browser.",
      "Execucao automatizada",
    )

  let assert Ok(_) = lesson.append(workspace, first)
  let assert Ok(_) = lesson.append(workspace, second)

  let recent = lesson.load_recent(workspace, 1)
  let assert [head] = recent
  head.lesson_type |> should.equal(lesson.ErrorLesson)
}

pub fn prompt_item_formats_type_and_context_test() {
  let item =
    lesson.make_success_lesson(
      "session-2",
      "Gerar checklist antes da resposta final.",
      "Planejamento",
    )
    |> lesson.to_prompt_item

  string.contains(item, "[Sucesso]") |> should.equal(True)
  string.contains(item, "Contexto: Planejamento") |> should.equal(True)
}

pub fn base_dir_paths_and_round_trip_test() {
  let state_dir = unique_workspace("state-dir") <> "/self"
  lesson.lessons_path_in(state_dir)
  |> should.equal(state_dir <> "/lessons.json")

  let entry =
    lesson.make_error_lesson("session-3", "Falha ao ler arquivo.", "IO")
  let assert Ok(_) = lesson.append_in(state_dir, entry)

  let assert Ok(content) = read_file(lesson.lessons_path_in(state_dir))
  string.contains(content, "Falha ao ler arquivo.") |> should.equal(True)
  lesson.load_recent_in(state_dir, 5)
  |> list.length
  |> should.equal(1)
}

pub fn workspace_paths_are_unchanged_test() {
  lesson.lessons_path("/tmp/ws")
  |> should.equal("/tmp/ws/.supernova/LESSONS.json")

  let workspace = unique_workspace("legacy")
  let entry = lesson.make_success_lesson("session-4", "Modo aberto.", "legado")
  let assert Ok(_) = lesson.append(workspace, entry)

  let assert Ok(_) = read_file(lesson.lessons_path(workspace))
  lesson.load_recent(workspace, 5)
  |> list.length
  |> should.equal(1)
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)
