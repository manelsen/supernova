import gleam/int
import gleam/string
import gleeunit/should
import supernova/core/introspection/lesson
import supernova/core/introspection/relationship
import supernova/core/introspection/self_state
import supernova/self/state_store

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

fn unique_base(prefix: String) -> String {
  "/tmp/supernova-state-store-" <> prefix <> "-" <> int.to_string(now_ms())
}

fn seed_legacy_files(workspace_path: String) -> Nil {
  let assert Ok(_) =
    lesson.append(
      workspace_path,
      lesson.make_success_lesson("sessao-1", "Licao legada.", "teste"),
    )
  let assert Ok(_) = self_state.save(workspace_path, self_state.default())
  let relationship_state = relationship.load(workspace_path, "telegram:1")
  let assert Ok(_) = relationship.save(workspace_path, relationship_state)
  Nil
}

pub fn paths_live_directly_under_self_dir_test() {
  state_store.lessons_path("/data/self")
  |> should.equal("/data/self/lessons.json")
  state_store.state_path("/data/self")
  |> should.equal("/data/self/state.json")
  state_store.relationship_path("/data/self")
  |> should.equal("/data/self/relationship.json")
}

pub fn migrate_moves_the_three_legacy_files_test() {
  let base = unique_base("migrate")
  let workspace_path = base <> "/workspace"
  let self_dir = base <> "/self"
  seed_legacy_files(workspace_path)

  let legacy_lessons = lesson.lessons_path(workspace_path)
  let legacy_state = self_state.self_state_path(workspace_path)
  let legacy_relationship = relationship.relationship_path(workspace_path)
  let assert Ok(lessons_before) = read_file(legacy_lessons)
  let assert Ok(state_before) = read_file(legacy_state)
  let assert Ok(relationship_before) = read_file(legacy_relationship)

  let assert Ok(Nil) = state_store.migrate_legacy(workspace_path, self_dir)

  file_exists(legacy_lessons) |> should.equal(Ok(False))
  file_exists(legacy_state) |> should.equal(Ok(False))
  file_exists(legacy_relationship) |> should.equal(Ok(False))

  read_file(lesson.lessons_path_in(self_dir))
  |> should.equal(Ok(lessons_before))
  read_file(self_state.state_path_in(self_dir))
  |> should.equal(Ok(state_before))
  read_file(relationship.relationship_path_in(self_dir))
  |> should.equal(Ok(relationship_before))
}

pub fn migrate_is_idempotent_test() {
  let base = unique_base("idempotent")
  let workspace_path = base <> "/workspace"
  let self_dir = base <> "/self"
  seed_legacy_files(workspace_path)

  let assert Ok(Nil) = state_store.migrate_legacy(workspace_path, self_dir)
  let assert Ok(first) = read_file(lesson.lessons_path_in(self_dir))

  let assert Ok(Nil) = state_store.migrate_legacy(workspace_path, self_dir)
  let assert Ok(second) = read_file(lesson.lessons_path_in(self_dir))

  second |> should.equal(first)
  file_exists(lesson.lessons_path(workspace_path))
  |> should.equal(Ok(False))
}

pub fn migrate_does_not_overwrite_existing_destination_test() {
  let base = unique_base("no-overwrite")
  let workspace_path = base <> "/workspace"
  let self_dir = base <> "/self"

  // Destination already has state; a leftover legacy file must not win.
  let assert Ok(_) =
    lesson.append_in(
      self_dir,
      lesson.make_success_lesson("sessao-2", "Licao nova.", "self"),
    )
  let assert Ok(_) =
    lesson.append(
      workspace_path,
      lesson.make_error_lesson("sessao-1", "Licao antiga.", "workspace"),
    )
  let assert Ok(before) = read_file(lesson.lessons_path_in(self_dir))

  let assert Ok(Nil) = state_store.migrate_legacy(workspace_path, self_dir)

  let assert Ok(after) = read_file(lesson.lessons_path_in(self_dir))
  after |> should.equal(before)
  string.contains(after, "Licao nova.") |> should.equal(True)
  string.contains(after, "Licao antiga.") |> should.equal(False)
  // The legacy file is deliberately left alone when the destination exists.
  file_exists(lesson.lessons_path(workspace_path))
  |> should.equal(Ok(True))
}

pub fn migrate_without_legacy_files_creates_nothing_test() {
  let base = unique_base("empty")
  let workspace_path = base <> "/workspace"
  let self_dir = base <> "/self"

  let assert Ok(Nil) = state_store.migrate_legacy(workspace_path, self_dir)

  file_exists(self_dir) |> should.equal(Ok(False))
}
