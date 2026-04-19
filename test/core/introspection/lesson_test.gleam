import gleam/int
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
