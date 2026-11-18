//// Tests for the Capability Manifest Actor module
////
//// Integration tests — with actors, with I/O.

import gleam/erlang/process
import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/capability_manifest/actor
import supernova/core/capability_manifest/types.{CapabilityManifest}
import test_workspace

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Actor Lifecycle Tests
// ============================================================================

pub fn start_and_stop_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)
  actor.stop(caps)

  // Give actor time to terminate
  process.sleep(100)
}

// ============================================================================
// allowed Tests — Default Manifest
// ============================================================================

pub fn default_allows_filesystem_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  actor.allowed(caps, "agent_1", "filesystem")
  |> should.be_true()

  actor.stop(caps)
  process.sleep(100)
}

pub fn default_allows_web_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  actor.allowed(caps, "agent_1", "web")
  |> should.be_true()

  actor.stop(caps)
  process.sleep(100)
}

pub fn default_denies_shell_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  actor.allowed(caps, "agent_1", "shell")
  |> should.be_false()

  actor.stop(caps)
  process.sleep(100)
}

pub fn default_denies_github_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  actor.allowed(caps, "agent_1", "github")
  |> should.be_false()

  actor.stop(caps)
  process.sleep(100)
}

pub fn default_denies_unknown_tool_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  actor.allowed(caps, "agent_1", "unknown_tool")
  |> should.be_false()

  actor.stop(caps)
  process.sleep(100)
}

// ============================================================================
// set_manifest / get_manifest Tests
// ============================================================================

pub fn set_and_get_manifest_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  let custom =
    CapabilityManifest(
      allowed_tools: ["my_tool", "another_tool"],
      denied_tools: ["dangerous_tool"],
    )
  actor.set_manifest(caps, "agent_1", custom)

  let manifest = actor.get_manifest(caps, "agent_1")
  list.length(manifest.allowed_tools)
  |> should.equal(2)

  list.length(manifest.denied_tools)
  |> should.equal(1)

  actor.stop(caps)
  process.sleep(100)
}

pub fn set_manifest_affects_allowed_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  // Before: shell is denied by default
  actor.allowed(caps, "agent_1", "shell")
  |> should.be_false()

  // Set custom manifest that allows shell
  let custom =
    CapabilityManifest(allowed_tools: ["shell"], denied_tools: ["filesystem"])
  actor.set_manifest(caps, "agent_1", custom)

  // After: shell is allowed
  actor.allowed(caps, "agent_1", "shell")
  |> should.be_true()

  // filesystem is now denied
  actor.allowed(caps, "agent_1", "filesystem")
  |> should.be_false()

  actor.stop(caps)
  process.sleep(100)
}

pub fn get_manifest_returns_default_for_unknown_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  let manifest = actor.get_manifest(caps, "unknown_agent")

  // Should be default manifest
  list.is_empty(manifest.allowed_tools)
  |> should.be_false

  list.is_empty(manifest.denied_tools)
  |> should.be_false

  actor.stop(caps)
  process.sleep(100)
}

// ============================================================================
// allow_tool / deny_tool Tests
// ============================================================================

pub fn allow_tool_adds_capability_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  // custom_tool not in default
  actor.allowed(caps, "agent_1", "custom_tool")
  |> should.be_false()

  // Allow it
  actor.allow_tool(caps, "agent_1", "custom_tool")

  actor.allowed(caps, "agent_1", "custom_tool")
  |> should.be_true()

  actor.stop(caps)
  process.sleep(100)
}

pub fn deny_tool_revokes_capability_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  // filesystem is allowed by default
  actor.allowed(caps, "agent_1", "filesystem")
  |> should.be_true()

  // Deny it
  actor.deny_tool(caps, "agent_1", "filesystem")

  actor.allowed(caps, "agent_1", "filesystem")
  |> should.be_false()

  actor.stop(caps)
  process.sleep(100)
}

// ============================================================================
// list_allowed / list_denied Tests
// ============================================================================

pub fn list_allowed_returns_default_tools_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  let allowed = actor.list_allowed(caps, "agent_1")

  list.is_empty(allowed)
  |> should.be_false

  actor.stop(caps)
  process.sleep(100)
}

pub fn list_denied_returns_default_tools_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  let denied = actor.list_denied(caps, "agent_1")

  list.is_empty(denied)
  |> should.be_false

  actor.stop(caps)
  process.sleep(100)
}

// ============================================================================
// Multi-Agent Tests
// ============================================================================

pub fn different_agents_have_independent_manifests_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  // Set custom manifest for agent_1
  let custom =
    CapabilityManifest(allowed_tools: ["shell"], denied_tools: ["filesystem"])
  actor.set_manifest(caps, "agent_1", custom)

  // agent_1 has custom
  actor.allowed(caps, "agent_1", "shell")
  |> should.be_true()

  // agent_2 still has default
  actor.allowed(caps, "agent_2", "shell")
  |> should.be_false()

  actor.allowed(caps, "agent_2", "filesystem")
  |> should.be_true()

  actor.stop(caps)
  process.sleep(100)
}

// ============================================================================
// Override Tests — Manifest Override by set_manifest
// ============================================================================

pub fn override_default_manifest_test() {
  use root <- test_workspace.with_isolated_workspace("cap-actor")
  let assert Ok(caps) = actor.start(root)

  // Default denies shell
  actor.allowed(caps, "agent_1", "shell")
  |> should.be_false()

  // Override: allow everything
  let override =
    CapabilityManifest(
      allowed_tools: ["filesystem", "web", "shell", "github"],
      denied_tools: [],
    )
  actor.set_manifest(caps, "agent_1", override)

  // Now everything is allowed
  actor.allowed(caps, "agent_1", "shell")
  |> should.be_true()

  actor.allowed(caps, "agent_1", "github")
  |> should.be_true()

  actor.allowed(caps, "agent_1", "filesystem")
  |> should.be_true()

  actor.stop(caps)
  process.sleep(100)
}
