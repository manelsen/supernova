//// Storage layout and one-shot migration for the agent's private state.
////
//// In closed-group mode lessons, self state and relationship live under
//// `<self_dir>/{lessons,state,relationship}.json`. Open mode keeps using the
//// legacy `<workspace>/.supernova/*` files.

import gleam/result
import supernova/core/introspection/lesson
import supernova/core/introspection/relationship
import supernova/core/introspection/self_state

pub fn lessons_path(self_dir: String) -> String {
  lesson.lessons_path_in(self_dir)
}

pub fn state_path(self_dir: String) -> String {
  self_state.state_path_in(self_dir)
}

pub fn relationship_path(self_dir: String) -> String {
  relationship.relationship_path_in(self_dir)
}

/// Move the three legacy workspace files into `self_dir`.
///
/// Each file is copied only when the legacy file exists and the destination
/// does not, then the legacy file is deleted. Calling it again is a no-op.
pub fn migrate_legacy(
  workspace_path: String,
  self_dir: String,
) -> Result(Nil, String) {
  let lessons_migration =
    migrate_file(
      from: lesson.lessons_path(workspace_path),
      to: lessons_path(self_dir),
      directory: self_dir,
    )
  use _ <- result.try(lessons_migration)

  let state_migration =
    migrate_file(
      from: self_state.self_state_path(workspace_path),
      to: state_path(self_dir),
      directory: self_dir,
    )
  use _ <- result.try(state_migration)

  migrate_file(
    from: relationship.relationship_path(workspace_path),
    to: relationship_path(self_dir),
    directory: self_dir,
  )
}

fn migrate_file(
  from from_path: String,
  to to_path: String,
  directory directory: String,
) -> Result(Nil, String) {
  use destination_exists <- result.try(ffi_file_exists(to_path))
  case destination_exists {
    True -> Ok(Nil)
    False -> {
      use legacy_exists <- result.try(ffi_file_exists(from_path))
      case legacy_exists {
        False -> Ok(Nil)
        True ->
          case ffi_read_file(from_path) {
            Error(reason) -> Error(reason)
            Ok(content) -> {
              use _ <- result.try(ffi_ensure_dir(directory))
              case ffi_write_file(to_path, content) {
                Error(reason) -> {
                  let _ = ffi_delete_file(to_path)
                  Error(reason)
                }
                Ok(_) -> ffi_delete_file(from_path)
              }
            }
          }
      }
    }
  }
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn ffi_write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ffi_ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn ffi_delete_file(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn ffi_file_exists(path: String) -> Result(Bool, String)
