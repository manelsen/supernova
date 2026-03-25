//// Tests for the Workspace Policy Actor module
////
//// Integration tests — with actors, with I/O.

import gleam/erlang/process
import gleeunit
import gleeunit/should
import supernova/core/workspace_policy/actor
import supernova/core/workspace_policy/types.{OpRead, OpWrite}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Actor Lifecycle Tests
// ============================================================================

pub fn start_and_stop_test() {
  let assert Ok(policy) = actor.start("workspaces")
  actor.stop(policy)

  // Give actor time to terminate
  process.sleep(100)
}

// ============================================================================
// authorize Tests
// ============================================================================

pub fn authorize_relative_read_test() {
  let assert Ok(policy) = actor.start("workspaces")

  let result = actor.authorize(policy, "agent_1", OpRead, "src/main.gleam")
  result
  |> should.be_ok()

  let assert Ok(path) = result
  path
  |> should.equal("workspaces/agent_1/src/main.gleam")

  actor.stop(policy)
  process.sleep(100)
}

pub fn authorize_relative_write_test() {
  let assert Ok(policy) = actor.start("workspaces")

  let result = actor.authorize(policy, "agent_1", OpWrite, "output.txt")
  result
  |> should.be_ok()

  let assert Ok(path) = result
  path
  |> should.equal("workspaces/agent_1/output.txt")

  actor.stop(policy)
  process.sleep(100)
}

pub fn authorize_denies_traversal_test() {
  let assert Ok(policy) = actor.start("workspaces")

  let result = actor.authorize(policy, "agent_1", OpRead, "../etc/passwd")
  result
  |> should.be_error()

  actor.stop(policy)
  process.sleep(100)
}

pub fn authorize_denies_absolute_path_test() {
  let assert Ok(policy) = actor.start("workspaces")

  let result = actor.authorize(policy, "agent_1", OpRead, "/etc/passwd")
  result
  |> should.be_error()

  actor.stop(policy)
  process.sleep(100)
}

pub fn authorize_external_read_when_allowed_test() {
  let assert Ok(policy) = actor.start("workspaces")

  // Set rule with external read allowed
  let rule = types.rule_with_external_read("agent_1")
  actor.set_rule(policy, "agent_1", rule)

  let result = actor.authorize(policy, "agent_1", OpRead, "/etc/config.txt")
  result
  |> should.be_ok()

  actor.stop(policy)
  process.sleep(100)
}

// ============================================================================
// set_rule / get_rule Tests
// ============================================================================

pub fn set_and_get_rule_test() {
  let assert Ok(policy) = actor.start("workspaces")

  let rule =
    types.PolicyRule(
      agent_id: "agent_1",
      allowed_paths: ["workspaces/agent_1/src"],
      denied_paths: [],
      external_read_allowed: True,
    )
  actor.set_rule(policy, "agent_1", rule)

  let retrieved = actor.get_rule(policy, "agent_1")
  retrieved.external_read_allowed
  |> should.equal(True)

  actor.stop(policy)
  process.sleep(100)
}

pub fn get_rule_returns_default_for_unknown_test() {
  let assert Ok(policy) = actor.start("workspaces")

  let rule = actor.get_rule(policy, "unknown_agent")
  rule.agent_id
  |> should.equal("unknown_agent")
  rule.external_read_allowed
  |> should.equal(False)

  actor.stop(policy)
  process.sleep(100)
}

// ============================================================================
// set_parent Tests — Sub-Agent Inheritance
// ============================================================================

pub fn set_parent_inherits_workspace_test() {
  let assert Ok(policy) = actor.start("workspaces")

  actor.set_parent(policy, "child", "parent")

  let workspace = actor.get_workspace(policy, "child")
  workspace
  |> should.equal("workspaces/parent")

  actor.stop(policy)
  process.sleep(100)
}

pub fn sub_agent_authorize_uses_parent_workspace_test() {
  let assert Ok(policy) = actor.start("workspaces")

  actor.set_parent(policy, "child", "parent")

  let result = actor.authorize(policy, "child", OpRead, "data.txt")
  result
  |> should.be_ok()

  let assert Ok(path) = result
  path
  |> should.equal("workspaces/parent/data.txt")

  actor.stop(policy)
  process.sleep(100)
}

pub fn agent_without_parent_has_own_workspace_test() {
  let assert Ok(policy) = actor.start("workspaces")

  let workspace = actor.get_workspace(policy, "agent_1")
  workspace
  |> should.equal("workspaces/agent_1")

  actor.stop(policy)
  process.sleep(100)
}

// ============================================================================
// allow_path / deny_path Tests
// ============================================================================

pub fn deny_path_blocks_access_test() {
  let assert Ok(policy) = actor.start("workspaces")

  actor.deny_path(policy, "agent_1", "workspaces/agent_1/secrets")

  let result = actor.authorize(policy, "agent_1", OpRead, "secrets/api_key.txt")
  result
  |> should.be_error()

  actor.stop(policy)
  process.sleep(100)
}

pub fn allow_path_permits_access_test() {
  let assert Ok(policy) = actor.start("workspaces")

  // Set explicit allowed paths
  let rule =
    types.PolicyRule(
      agent_id: "agent_1",
      allowed_paths: ["workspaces/agent_1/src"],
      denied_paths: [],
      external_read_allowed: False,
    )
  actor.set_rule(policy, "agent_1", rule)

  let result = actor.authorize(policy, "agent_1", OpRead, "src/main.gleam")
  result
  |> should.be_ok()

  actor.stop(policy)
  process.sleep(100)
}
