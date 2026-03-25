//// Tests for the Session Context module.
////
//// Verifies session context management: bindings, workspace path, scope.

import gleam/option.{None, Some}
import gleeunit/should
import supernova/core/session/context

pub fn new_context_has_correct_session_id_test() {
  let ctx = context.new("session_001")

  ctx.session_id
  |> should.equal("session_001")
}

pub fn new_context_has_empty_bindings_test() {
  let ctx = context.new("session_002")

  context.get_binding(ctx, "anything")
  |> should.equal(None)
}

pub fn set_and_get_binding_test() {
  let ctx = context.new("session_003")

  let ctx = context.set_binding(ctx, "model", "gpt-4")

  context.get_binding(ctx, "model")
  |> should.equal(Some("gpt-4"))
}

pub fn set_multiple_bindings_test() {
  let ctx = context.new("session_004")

  let ctx = context.set_binding(ctx, "key1", "value1")
  let ctx = context.set_binding(ctx, "key2", "value2")

  context.get_binding(ctx, "key1")
  |> should.equal(Some("value1"))

  context.get_binding(ctx, "key2")
  |> should.equal(Some("value2"))
}

pub fn overwrite_binding_test() {
  let ctx = context.new("session_005")

  let ctx = context.set_binding(ctx, "key", "old")
  let ctx = context.set_binding(ctx, "key", "new")

  context.get_binding(ctx, "key")
  |> should.equal(Some("new"))
}

pub fn default_workspace_path_test() {
  let ctx = context.new("session_006")

  ctx.workspace_path
  |> should.equal("/tmp/supernova/session_006")
}

pub fn set_workspace_path_test() {
  let ctx = context.new("session_007")

  let ctx = context.set_workspace_path(ctx, "/home/user/project")

  ctx.workspace_path
  |> should.equal("/home/user/project")
}
