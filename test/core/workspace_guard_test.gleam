//// Tests for Workspace Guard.

import gleeunit/should
import supernova/core/workspace_guard

pub fn validate_path_within_workspace_test() {
  let result =
    workspace_guard.validate_path("/home/user/project", "src/main.gleam")

  result
  |> should.be_ok
}

pub fn block_path_traversal_test() {
  let result =
    workspace_guard.validate_path("/home/user/project", "../etc/passwd")

  result
  |> should.be_error
}

pub fn block_nested_traversal_test() {
  let result =
    workspace_guard.validate_path("/home/user/project", "src/../../etc/passwd")

  result
  |> should.be_error
}

pub fn allow_subdirectory_test() {
  let result =
    workspace_guard.validate_path("/home/user/project", "src/lib/utils.gleam")

  result
  |> should.be_ok
}

pub fn block_absolute_path_test() {
  let result =
    workspace_guard.validate_path("/home/user/project", "/etc/passwd")

  result
  |> should.be_error
}

pub fn full_path_returned_test() {
  let assert Ok(full_path) =
    workspace_guard.validate_path("/home/user/project", "src/main.gleam")

  full_path
  |> should.equal("/home/user/project/src/main.gleam")
}
