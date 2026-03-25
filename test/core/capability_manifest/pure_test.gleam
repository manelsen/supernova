//// Tests for the Capability Manifest Pure module
////
//// Pure tests — no I/O, no actors, no FFI.

import gleam/dict
import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/capability_manifest/pure
import supernova/core/capability_manifest/types.{
  type CapabilityManifest, type CapabilityManifestState, CapabilityManifest,
  CapabilityManifestState,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helpers
// ============================================================================

fn empty_state() -> CapabilityManifestState {
  CapabilityManifestState(manifests: dict.new(), workspace_root: "workspaces")
}

fn custom_manifest() -> CapabilityManifest {
  CapabilityManifest(
    allowed_tools: ["filesystem", "web", "custom_tool"],
    denied_tools: ["shell", "github"],
  )
}

// ============================================================================
// allowed Tests — Tool Permitted
// ============================================================================

pub fn allowed_tool_in_allowed_list_test() {
  let manifest = custom_manifest()

  pure.allowed(manifest, "filesystem")
  |> should.be_true()
}

pub fn allowed_tool_in_allowed_list_web_test() {
  let manifest = custom_manifest()

  pure.allowed(manifest, "web")
  |> should.be_true()
}

pub fn allowed_custom_tool_test() {
  let manifest = custom_manifest()

  pure.allowed(manifest, "custom_tool")
  |> should.be_true()
}

// ============================================================================
// allowed Tests — Tool Denied
// ============================================================================

pub fn denied_tool_in_denied_list_test() {
  let manifest = custom_manifest()

  pure.allowed(manifest, "shell")
  |> should.be_false()
}

pub fn denied_tool_in_denied_list_github_test() {
  let manifest = custom_manifest()

  pure.allowed(manifest, "github")
  |> should.be_false()
}

pub fn denied_tool_not_in_any_list_test() {
  let manifest = custom_manifest()

  // Tool not in allowed or denied → default-deny
  pure.allowed(manifest, "unknown_tool")
  |> should.be_false()
}

pub fn denied_takes_precedence_over_allowed_test() {
  let manifest =
    CapabilityManifest(allowed_tools: ["filesystem", "shell"], denied_tools: [
      "shell",
    ])

  // shell is in both lists — denied takes precedence
  pure.allowed(manifest, "shell")
  |> should.be_false()
}

// ============================================================================
// default_manifest Tests
// ============================================================================

pub fn default_manifest_allows_filesystem_test() {
  let manifest = types.default_manifest()

  pure.allowed(manifest, "filesystem")
  |> should.be_true()
}

pub fn default_manifest_allows_web_test() {
  let manifest = types.default_manifest()

  pure.allowed(manifest, "web")
  |> should.be_true()
}

pub fn default_manifest_denies_shell_test() {
  let manifest = types.default_manifest()

  pure.allowed(manifest, "shell")
  |> should.be_false()
}

pub fn default_manifest_denies_github_test() {
  let manifest = types.default_manifest()

  pure.allowed(manifest, "github")
  |> should.be_false()
}

pub fn default_manifest_denies_unknown_test() {
  let manifest = types.default_manifest()

  pure.allowed(manifest, "unknown_tool")
  |> should.be_false()
}

pub fn default_manifest_allows_read_file_test() {
  let manifest = types.default_manifest()

  pure.allowed(manifest, "read_file")
  |> should.be_true()
}

pub fn default_manifest_denies_execute_command_test() {
  let manifest = types.default_manifest()

  pure.allowed(manifest, "execute_command")
  |> should.be_false()
}

// ============================================================================
// for_agent Tests
// ============================================================================

pub fn for_agent_returns_default_when_not_set_test() {
  let state = empty_state()

  let manifest = pure.for_agent(state, "agent_1")

  // Should be the default manifest
  pure.allowed(manifest, "filesystem")
  |> should.be_true()

  pure.allowed(manifest, "shell")
  |> should.be_false()
}

pub fn for_agent_returns_custom_when_set_test() {
  let state = empty_state()
  let custom = custom_manifest()

  let state = pure.set_manifest(state, "agent_1", custom)
  let manifest = pure.for_agent(state, "agent_1")

  pure.allowed(manifest, "custom_tool")
  |> should.be_true()
}

pub fn for_agent_different_agents_independent_test() {
  let state = empty_state()
  let custom =
    CapabilityManifest(allowed_tools: ["shell"], denied_tools: ["filesystem"])

  let state = pure.set_manifest(state, "agent_1", custom)

  // agent_1 has custom manifest
  let manifest_1 = pure.for_agent(state, "agent_1")
  pure.allowed(manifest_1, "shell")
  |> should.be_true()

  // agent_2 has default manifest
  let manifest_2 = pure.for_agent(state, "agent_2")
  pure.allowed(manifest_2, "shell")
  |> should.be_false()
  pure.allowed(manifest_2, "filesystem")
  |> should.be_true()
}

// ============================================================================
// set_manifest Tests
// ============================================================================

pub fn set_manifest_overwrites_existing_test() {
  let state = empty_state()
  let custom_1 = CapabilityManifest(allowed_tools: ["tool_a"], denied_tools: [])
  let custom_2 = CapabilityManifest(allowed_tools: ["tool_b"], denied_tools: [])

  let state = pure.set_manifest(state, "agent_1", custom_1)
  let state = pure.set_manifest(state, "agent_1", custom_2)

  let manifest = pure.for_agent(state, "agent_1")
  pure.allowed(manifest, "tool_a")
  |> should.be_false()

  pure.allowed(manifest, "tool_b")
  |> should.be_true()
}

// ============================================================================
// agent_allowed Tests — Combined Operation
// ============================================================================

pub fn agent_allowed_with_default_manifest_test() {
  let state = empty_state()

  pure.agent_allowed(state, "agent_1", "filesystem")
  |> should.be_true()

  pure.agent_allowed(state, "agent_1", "shell")
  |> should.be_false()
}

pub fn agent_allowed_with_custom_manifest_test() {
  let state = empty_state()
  let custom =
    CapabilityManifest(allowed_tools: ["my_tool"], denied_tools: ["filesystem"])

  let state = pure.set_manifest(state, "agent_1", custom)

  pure.agent_allowed(state, "agent_1", "my_tool")
  |> should.be_true()

  pure.agent_allowed(state, "agent_1", "filesystem")
  |> should.be_false()
}

// ============================================================================
// allow_tool / deny_tool Tests
// ============================================================================

pub fn allow_tool_adds_to_manifest_test() {
  let state = empty_state()

  let state = pure.allow_tool(state, "agent_1", "new_tool")

  pure.agent_allowed(state, "agent_1", "new_tool")
  |> should.be_true()
}

pub fn deny_tool_blocks_tool_test() {
  let state = empty_state()

  // filesystem is allowed by default
  pure.agent_allowed(state, "agent_1", "filesystem")
  |> should.be_true()

  // Deny it
  let state = pure.deny_tool(state, "agent_1", "filesystem")

  pure.agent_allowed(state, "agent_1", "filesystem")
  |> should.be_false()
}

// ============================================================================
// list_allowed / list_denied Tests
// ============================================================================

pub fn list_allowed_returns_tools_test() {
  let state = empty_state()

  let allowed = pure.list_allowed(state, "agent_1")

  // Default manifest has filesystem, web, etc.
  list.length(allowed)
  |> should.equal(list.length(types.default_manifest().allowed_tools))
}

pub fn list_denied_returns_tools_test() {
  let state = empty_state()

  let denied = pure.list_denied(state, "agent_1")

  // Default manifest has shell, github, etc.
  list.length(denied)
  |> should.equal(list.length(types.default_manifest().denied_tools))
}

pub fn list_allowed_empty_for_empty_manifest_test() {
  let state = empty_state()
  let empty_manifest = CapabilityManifest(allowed_tools: [], denied_tools: [])

  let state = pure.set_manifest(state, "agent_1", empty_manifest)
  let allowed = pure.list_allowed(state, "agent_1")

  list.is_empty(allowed)
  |> should.be_true()
}

// ============================================================================
// remove_manifest Tests
// ============================================================================

pub fn remove_manifest_resets_to_default_test() {
  let state = empty_state()
  let custom =
    CapabilityManifest(allowed_tools: ["shell"], denied_tools: ["filesystem"])

  let state = pure.set_manifest(state, "agent_1", custom)

  // Verify custom is set
  pure.agent_allowed(state, "agent_1", "shell")
  |> should.be_true()

  // Remove it
  let state = pure.remove_manifest(state, "agent_1")

  // Should fall back to default
  pure.agent_allowed(state, "agent_1", "shell")
  |> should.be_false()

  pure.agent_allowed(state, "agent_1", "filesystem")
  |> should.be_true()
}
