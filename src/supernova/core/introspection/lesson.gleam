import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type LessonType {
  ErrorLesson
  SuccessLesson
}

pub type Lesson {
  Lesson(
    id: String,
    lesson_type: LessonType,
    content: String,
    context: String,
    created_at: Int,
    session_id: String,
  )
}

/// Legacy workspace location, still used in open mode.
pub fn lessons_path(workspace_path: String) -> String {
  workspace_path <> "/.supernova/LESSONS.json"
}

/// Lessons file inside a caller-supplied state directory (closed-group mode).
pub fn lessons_path_in(state_dir: String) -> String {
  state_dir <> "/lessons.json"
}

pub fn make_error_lesson(
  session_id: String,
  content: String,
  context: String,
) -> Lesson {
  let created_at = now_ms()
  Lesson(
    id: lesson_id(session_id, "error", created_at),
    lesson_type: ErrorLesson,
    content: string.trim(content),
    context: string.trim(context),
    created_at: created_at,
    session_id: session_id,
  )
}

pub fn make_success_lesson(
  session_id: String,
  content: String,
  context: String,
) -> Lesson {
  let created_at = now_ms()
  Lesson(
    id: lesson_id(session_id, "success", created_at),
    lesson_type: SuccessLesson,
    content: string.trim(content),
    context: string.trim(context),
    created_at: created_at,
    session_id: session_id,
  )
}

pub fn append(workspace_path: String, lesson: Lesson) -> Result(Nil, String) {
  append_at(
    lessons_path(workspace_path),
    workspace_path <> "/.supernova",
    lesson,
  )
}

/// Append to the lessons file inside a caller-supplied state directory.
pub fn append_in(state_dir: String, lesson: Lesson) -> Result(Nil, String) {
  append_at(lessons_path_in(state_dir), state_dir, lesson)
}

fn append_at(
  file_path: String,
  directory: String,
  lesson: Lesson,
) -> Result(Nil, String) {
  let existing = load_all(file_path)
  let sorted =
    [lesson, ..existing]
    |> list.sort(fn(a, b) { int.compare(b.created_at, a.created_at) })
    |> dedupe_by_id([])
    |> list.take(100)

  use _ <- result.try(ffi_ensure_dir(directory))
  ffi_write_file(file_path, encode_lessons(sorted))
}

pub fn load_recent(workspace_path: String, limit: Int) -> List(Lesson) {
  load_recent_at(lessons_path(workspace_path), limit)
}

/// Load recent lessons from a caller-supplied state directory.
pub fn load_recent_in(state_dir: String, limit: Int) -> List(Lesson) {
  load_recent_at(lessons_path_in(state_dir), limit)
}

fn load_recent_at(file_path: String, limit: Int) -> List(Lesson) {
  load_all(file_path)
  |> list.sort(fn(a, b) { int.compare(b.created_at, a.created_at) })
  |> list.take(limit)
}

pub fn to_prompt_item(lesson: Lesson) -> String {
  "["
  <> lesson_type_label(lesson.lesson_type)
  <> "] "
  <> lesson.content
  <> "\nContexto: "
  <> lesson.context
}

fn load_all(file_path: String) -> List(Lesson) {
  case ffi_read_file(file_path) {
    Error(_) -> []
    Ok(content) ->
      case json.parse(from: content, using: decode.list(lesson_decoder())) {
        Ok(lessons) -> lessons
        Error(_) -> []
      }
  }
}

fn lesson_decoder() -> decode.Decoder(Lesson) {
  use id <- decode.field("id", decode.string)
  use kind <- decode.field("lesson_type", decode.string)
  use content <- decode.field("content", decode.string)
  use context <- decode.field("context", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use session_id <- decode.field("session_id", decode.string)

  decode.success(Lesson(
    id: id,
    lesson_type: parse_lesson_type(kind),
    content: content,
    context: context,
    created_at: created_at,
    session_id: session_id,
  ))
}

fn parse_lesson_type(value: String) -> LessonType {
  case string.lowercase(value) {
    "error" -> ErrorLesson
    "success" -> SuccessLesson
    _ -> SuccessLesson
  }
}

fn lesson_type_text(value: LessonType) -> String {
  case value {
    ErrorLesson -> "error"
    SuccessLesson -> "success"
  }
}

fn lesson_type_label(value: LessonType) -> String {
  case value {
    ErrorLesson -> "Erro"
    SuccessLesson -> "Sucesso"
  }
}

fn dedupe_by_id(remaining: List(Lesson), acc: List(Lesson)) -> List(Lesson) {
  case remaining {
    [] -> list.reverse(acc)
    [current, ..rest] ->
      case list.any(acc, fn(existing) { existing.id == current.id }) {
        True -> dedupe_by_id(rest, acc)
        False -> dedupe_by_id(rest, [current, ..acc])
      }
  }
}

fn encode_lessons(lessons: List(Lesson)) -> String {
  "[" <> string.join(list.map(lessons, encode_lesson), ",") <> "]"
}

fn encode_lesson(lesson: Lesson) -> String {
  "{"
  <> "\"id\":\""
  <> escape(lesson.id)
  <> "\","
  <> "\"lesson_type\":\""
  <> lesson_type_text(lesson.lesson_type)
  <> "\","
  <> "\"content\":\""
  <> escape(lesson.content)
  <> "\","
  <> "\"context\":\""
  <> escape(lesson.context)
  <> "\","
  <> "\"created_at\":"
  <> int.to_string(lesson.created_at)
  <> ","
  <> "\"session_id\":\""
  <> escape(lesson.session_id)
  <> "\"}"
}

fn lesson_id(session_id: String, prefix: String, created_at: Int) -> String {
  prefix <> ":" <> session_id <> ":" <> int.to_string(created_at)
}

fn escape(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

@external(erlang, "supernova_file_system_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn ffi_write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ffi_ensure_dir(path: String) -> Result(Nil, String)
