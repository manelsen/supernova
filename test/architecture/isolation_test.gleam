//// Architecture isolation tests.
////
//// These tests enforce that shared-memory primitives are not wired into the
//// rest of the kernel/userland before per-principal access control exists.
//// Kept as a source-level check because the rule is about module boundaries
//// rather than about runtime behaviour.

import gleam/int
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

const shared_memory_failure_message =
  "blackboard/memory_federation share memory across agents without access control; wire them only through the syscall gateway after PRD B3"

const orchestrator_failure_message =
  "project orchestrator uses a blackboard; wire it only after PRD B3 defines per-principal isolation"

const blackboard_module = "supernova/core/blackboard"

const memory_federation_module = "supernova/core/memory_federation"

const orchestrator_module = "supernova/core/project/actor"

// Explicit allowlist. Everything else under src/ must not import the
// blackboard or the memory federation.
const blackboard_exception = "src/supernova/core/blackboard.gleam"

// Same-owner orchestration: the blackboard is injected per project and must
// never be shared across principals.
const orchestrator_exception = "src/supernova/core/project/actor.gleam"

const memory_federation_exception_prefix =
  "src/supernova/core/memory_federation/"

const project_prefix = "src/supernova/core/project/"

pub fn no_shared_memory_imports_test() {
  let files = source_files()

  let violations =
    list.flat_map(files, fn(path) {
      case shared_memory_exception(path) {
        True -> []
        False ->
          forbidden_imports(path, [blackboard_module, memory_federation_module])
      }
    })

  assert_no_violations(violations, shared_memory_failure_message)
}

pub fn orchestrator_only_inside_project_test() {
  let files = source_files()

  let violations =
    list.flat_map(files, fn(path) {
      case string.starts_with(path, project_prefix) {
        True -> []
        False -> forbidden_imports(path, [orchestrator_module])
      }
    })

  assert_no_violations(violations, orchestrator_failure_message)
}

// ============================================================================
// Helpers
// ============================================================================

fn source_files() -> List(String) {
  let files = ffi_gleam_files_under("src")
  should.be_true(files != [])
  files
}

fn shared_memory_exception(path: String) -> Bool {
  path == blackboard_exception
  || path == orchestrator_exception
  || string.starts_with(path, memory_federation_exception_prefix)
}

fn forbidden_imports(path: String, modules: List(String)) -> List(String) {
  let contents = ffi_read_file(path)

  contents
  |> string.split("\n")
  |> list.index_map(fn(line, index) { #(index + 1, line) })
  |> list.filter(fn(entry) {
    let #(_, line) = entry
    list.any(modules, fn(module) { is_import_of(line, module) })
  })
  |> list.map(fn(entry) {
    let #(line_number, line) = entry
    path <> ":" <> int.to_string(line_number) <> ": " <> string.trim(line)
  })
}

fn is_import_of(line: String, module: String) -> Bool {
  let trimmed = string.trim(line)
  let prefix = "import " <> module

  case string.starts_with(trimmed, prefix) {
    False -> False
    True -> {
      let rest = string.drop_start(trimmed, string.length(prefix))
      rest == ""
      || string.starts_with(rest, ".")
      || string.starts_with(rest, " ")
    }
  }
}

fn assert_no_violations(violations: List(String), message: String) -> Nil {
  case violations {
    [] -> Nil
    _ -> {
      let full_message =
        message <> "\n\nOffending imports:\n" <> string.join(violations, "\n")
      panic as full_message
    }
  }
}

@external(erlang, "isolation_test_ffi", "gleam_files_under")
fn ffi_gleam_files_under(dir: String) -> List(String)

@external(erlang, "isolation_test_ffi", "read_file")
fn ffi_read_file(path: String) -> String
