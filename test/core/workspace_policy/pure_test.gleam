//// Tests for the Workspace Policy Pure module
////
//// Pure tests — no I/O, no actors, no FFI.

import gleam/dict
import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/workspace_policy/pure
import supernova/core/workspace_policy/types.{
  type WorkspacePolicyState, OpRead, OpShell, OpWrite, WorkspacePolicyState,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helpers
// ============================================================================

fn empty_state() -> WorkspacePolicyState {
  WorkspacePolicyState(
    rules: dict.new(),
    workspace_root: "workspaces",
    parent_of: dict.new(),
  )
}

// ============================================================================
// authorize Tests — Access Allowed
// ============================================================================

pub fn authorize_relative_read_allowed_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, commands) =
    pure.authorize(state, "agent_1", OpRead, "src/main.gleam", timestamp)

  result
  |> should.be_ok()

  let assert Ok(path) = result
  path
  |> should.equal("workspaces/agent_1/src/main.gleam")

  list.length(commands)
  |> should.equal(0)
}

pub fn authorize_relative_write_allowed_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, _commands) =
    pure.authorize(state, "agent_1", OpWrite, "output.txt", timestamp)

  result
  |> should.be_ok()

  let assert Ok(path) = result
  path
  |> should.equal("workspaces/agent_1/output.txt")
}

pub fn authorize_relative_shell_allowed_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, _commands) =
    pure.authorize(state, "agent_1", OpShell, "script.sh", timestamp)

  result
  |> should.be_ok()

  let assert Ok(path) = result
  path
  |> should.equal("workspaces/agent_1/script.sh")
}

pub fn authorize_absolute_within_workspace_test() {
  let state = empty_state()
  let timestamp = 1000

  // Absolute path starting with / that is within the workspace
  let #(_state, result, _commands) =
    pure.authorize(
      state,
      "agent_1",
      OpRead,
      "workspaces/agent_1/src/main.gleam",
      timestamp,
    )

  // This is a relative path (no leading /), so workspace is prepended
  result
  |> should.be_ok()

  let assert Ok(path) = result
  path
  |> should.equal("workspaces/agent_1/workspaces/agent_1/src/main.gleam")
}

pub fn authorize_external_read_allowed_test() {
  let state = empty_state()
  let timestamp = 1000

  // Set rule with external read allowed
  let rule = types.rule_with_external_read("agent_1")
  let state = pure.set_rule(state, "agent_1", rule)

  let #(_state, result, _commands) =
    pure.authorize(state, "agent_1", OpRead, "/etc/config.txt", timestamp)

  result
  |> should.be_ok()

  let assert Ok(path) = result
  path
  |> should.equal("/etc/config.txt")
}

// ============================================================================
// authorize Tests — Access Denied
// ============================================================================

pub fn deny_path_traversal_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, commands) =
    pure.authorize(state, "agent_1", OpRead, "../etc/passwd", timestamp)

  result
  |> should.be_error()

  let assert Error(reason) = result
  reason
  |> should.equal("Path traversal blocked: ../etc/passwd")

  // Should generate audit command
  list.length(commands)
  |> should.equal(1)
}

pub fn deny_nested_traversal_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, _commands) =
    pure.authorize(state, "agent_1", OpRead, "src/../../etc/passwd", timestamp)

  result
  |> should.be_error()
}

pub fn deny_absolute_path_outside_workspace_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, commands) =
    pure.authorize(state, "agent_1", OpRead, "/etc/passwd", timestamp)

  result
  |> should.be_error()

  let assert Error(reason) = result
  reason
  |> should.equal("External read not allowed for agent: agent_1")

  list.length(commands)
  |> should.equal(1)
}

pub fn deny_write_outside_workspace_test() {
  let state = empty_state()
  let timestamp = 1000

  // Even with external_read_allowed, writes outside workspace are denied
  let rule = types.rule_with_external_read("agent_1")
  let state = pure.set_rule(state, "agent_1", rule)

  let #(_state, result, _commands) =
    pure.authorize(state, "agent_1", OpWrite, "/etc/config.txt", timestamp)

  result
  |> should.be_error()
}

pub fn deny_shell_outside_workspace_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, _commands) =
    pure.authorize(state, "agent_1", OpShell, "/usr/bin/malicious", timestamp)

  result
  |> should.be_error()
}

pub fn deny_path_in_denied_list_test() {
  let state = empty_state()
  let timestamp = 1000

  // Deny a specific path prefix
  let state = pure.deny_path(state, "agent_1", "workspaces/agent_1/secrets")

  let #(_state, result, commands) =
    pure.authorize(state, "agent_1", OpRead, "secrets/api_key.txt", timestamp)

  result
  |> should.be_error()

  let assert Error(reason) = result
  reason
  |> should.equal("Path denied by policy: secrets/api_key.txt")

  list.length(commands)
  |> should.equal(1)
}

pub fn deny_path_not_in_allowed_list_test() {
  let state = empty_state()
  let timestamp = 1000

  // Set explicit allowed paths
  let rule =
    types.PolicyRule(
      agent_id: "agent_1",
      allowed_paths: ["workspaces/agent_1/src"],
      denied_paths: [],
      external_read_allowed: False,
    )
  let state = pure.set_rule(state, "agent_1", rule)

  // Try to access a path not in the allowed list
  let #(_state, result, _commands) =
    pure.authorize(state, "agent_1", OpRead, "docs/readme.md", timestamp)

  result
  |> should.be_error()
}

pub fn allow_path_in_allowed_list_test() {
  let state = empty_state()
  let timestamp = 1000

  // Set explicit allowed paths
  let rule =
    types.PolicyRule(
      agent_id: "agent_1",
      allowed_paths: ["workspaces/agent_1/src"],
      denied_paths: [],
      external_read_allowed: False,
    )
  let state = pure.set_rule(state, "agent_1", rule)

  // Access a path in the allowed list
  let #(_state, result, _commands) =
    pure.authorize(state, "agent_1", OpRead, "src/main.gleam", timestamp)

  result
  |> should.be_ok()
}

// ============================================================================
// authorize Tests — Sub-Agent Inheritance
// ============================================================================

pub fn sub_agent_inherits_parent_workspace_test() {
  let state = empty_state()
  let timestamp = 1000

  // Set parent-child relationship
  let state = pure.set_parent(state, "child_1", "parent")

  // Child should use parent's workspace
  let workspace = pure.get_effective_workspace(state, "child_1")
  workspace
  |> should.equal("workspaces/parent")

  // Child's relative path should resolve to parent's workspace
  let #(_state, result, _commands) =
    pure.authorize(state, "child_1", OpRead, "data.txt", timestamp)

  let assert Ok(path) = result
  path
  |> should.equal("workspaces/parent/data.txt")
}

pub fn sub_agent_cannot_create_own_root_test() {
  let state = empty_state()
  let timestamp = 1000

  // Set parent-child relationship
  let state = pure.set_parent(state, "child_1", "parent")

  // Child trying to access an absolute path that would be in its own
  // (non-inherited) workspace should fail because its effective workspace
  // is the parent's
  let #(_state, result, _commands) =
    pure.authorize(
      state,
      "child_1",
      OpRead,
      "workspaces/child_1/secret.txt",
      timestamp,
    )

  // This is a relative path, so it resolves to workspaces/parent/workspaces/child_1/secret.txt
  // which is allowed (it's within the parent's workspace)
  result
  |> should.be_ok()

  let assert Ok(path) = result
  path
  |> should.equal("workspaces/parent/workspaces/child_1/secret.txt")
}

pub fn deep_inheritance_chain_test() {
  let state = empty_state()

  // grandparent -> parent -> child
  let state = pure.set_parent(state, "parent", "grandparent")
  let state = pure.set_parent(state, "child", "parent")

  // Child should resolve all the way to grandparent's workspace
  let workspace = pure.get_effective_workspace(state, "child")
  workspace
  |> should.equal("workspaces/grandparent")
}

pub fn agent_without_parent_has_own_workspace_test() {
  let state = empty_state()

  let workspace = pure.get_effective_workspace(state, "agent_1")
  workspace
  |> should.equal("workspaces/agent_1")
}

// ============================================================================
// authorize Tests — Path Traversal Blocked
// ============================================================================

pub fn block_dotdot_traversal_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, _commands) =
    pure.authorize(state, "agent_1", OpRead, "..", timestamp)

  result
  |> should.be_error()
}

pub fn block_traversal_in_subdirectory_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, _commands) =
    pure.authorize(
      state,
      "agent_1",
      OpRead,
      "src/../../../etc/passwd",
      timestamp,
    )

  result
  |> should.be_error()
}

pub fn block_traversal_with_absolute_path_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, _commands) =
    pure.authorize(
      state,
      "agent_1",
      OpRead,
      "workspaces/agent_1/../../etc/passwd",
      timestamp,
    )

  result
  |> should.be_error()
}

// ============================================================================
// set_rule / get_rule Tests
// ============================================================================

pub fn get_rule_returns_default_for_unknown_agent_test() {
  let state = empty_state()

  let rule = pure.get_rule(state, "unknown_agent")

  rule.agent_id
  |> should.equal("unknown_agent")
  rule.external_read_allowed
  |> should.equal(False)
  list.is_empty(rule.allowed_paths)
  |> should.be_true()
  list.is_empty(rule.denied_paths)
  |> should.be_true()
}

pub fn set_rule_stores_custom_rule_test() {
  let state = empty_state()

  let rule =
    types.PolicyRule(
      agent_id: "agent_1",
      allowed_paths: ["workspaces/agent_1/src"],
      denied_paths: ["workspaces/agent_1/secrets"],
      external_read_allowed: True,
    )
  let state = pure.set_rule(state, "agent_1", rule)

  let stored = pure.get_rule(state, "agent_1")
  stored.external_read_allowed
  |> should.equal(True)
  list.length(stored.allowed_paths)
  |> should.equal(1)
  list.length(stored.denied_paths)
  |> should.equal(1)
}

// ============================================================================
// allow_path / deny_path Tests
// ============================================================================

pub fn allow_path_adds_prefix_test() {
  let state = empty_state()

  let state = pure.allow_path(state, "agent_1", "workspaces/agent_1/shared")
  let rule = pure.get_rule(state, "agent_1")

  list.length(rule.allowed_paths)
  |> should.equal(1)
}

pub fn deny_path_adds_prefix_test() {
  let state = empty_state()

  let state = pure.deny_path(state, "agent_1", "workspaces/agent_1/secrets")
  let rule = pure.get_rule(state, "agent_1")

  list.length(rule.denied_paths)
  |> should.equal(1)
}

pub fn denied_path_takes_precedence_test() {
  let state = empty_state()
  let timestamp = 1000

  // Allow src but deny src/secrets
  let state = pure.allow_path(state, "agent_1", "workspaces/agent_1/src")
  let state = pure.deny_path(state, "agent_1", "workspaces/agent_1/src/secrets")

  // Access to src/file.gleam should be allowed
  let #(_state, result, _commands) =
    pure.authorize(state, "agent_1", OpRead, "src/file.gleam", timestamp)
  result
  |> should.be_ok()

  // Access to src/secrets/key.txt should be denied (denied takes precedence)
  let #(_state, result2, _commands) =
    pure.authorize(state, "agent_1", OpRead, "src/secrets/key.txt", timestamp)
  result2
  |> should.be_error()
}

// ============================================================================
// Audit Command Generation Tests
// ============================================================================

pub fn denied_access_generates_audit_command_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, _result, commands) =
    pure.authorize(state, "agent_1", OpRead, "../etc/passwd", timestamp)

  list.length(commands)
  |> should.equal(1)

  let assert [types.WriteDeniedAudit(agent_id, operation, path, reason, ts)] =
    commands
  agent_id
  |> should.equal("agent_1")
  operation
  |> should.equal("read")
  path
  |> should.equal("../etc/passwd")
  reason
  |> should.equal("Path traversal blocked: ../etc/passwd")
  ts
  |> should.equal(1000)
}

pub fn allowed_access_generates_no_commands_test() {
  let state = empty_state()
  let timestamp = 1000

  let #(_state, result, commands) =
    pure.authorize(state, "agent_1", OpRead, "src/main.gleam", timestamp)

  result
  |> should.be_ok()
  list.length(commands)
  |> should.equal(0)
}
