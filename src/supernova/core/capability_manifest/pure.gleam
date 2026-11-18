//// Capability Manifest — Pure Functions
////
//// Pure functions for tool capability enforcement. No FFI, no side effects.
//// Functions take state and return new state + commands for the actor to execute.
////
//// ## Usage
////
//// ```gleam
//// let allowed = pure.allowed(manifest, "filesystem")
//// let #(state, manifest) = pure.for_agent(state, "agent_1")
//// ```

import gleam/dict
import gleam/list
import supernova/core/capability_manifest/types.{
  type CapabilityManifest, type CapabilityManifestState, CapabilityManifest,
  CapabilityManifestState,
}

// ============================================================================
// Public API
// ============================================================================

/// Check if a tool is allowed for a given manifest.
///
/// Rules:
/// 1. If tool is in denied_tools → denied
/// 2. If tool is in allowed_tools → allowed
/// 3. If tool is in neither → denied (default-deny)
pub fn allowed(manifest: CapabilityManifest, tool_name: String) -> Bool {
  // Denied takes precedence. `*` grants every tool to a role.
  case list.contains(manifest.denied_tools, tool_name) {
    True -> False
    False ->
      list.contains(manifest.allowed_tools, "*")
      || list.contains(manifest.allowed_tools, tool_name)
  }
}

/// Get the capability manifest for an agent.
/// Returns the agent's manifest, or the default manifest if not set.
pub fn for_agent(
  state: CapabilityManifestState,
  agent_id: String,
) -> CapabilityManifest {
  case dict.get(state.manifests, agent_id) {
    Ok(manifest) -> manifest
    Error(_) -> types.default_manifest()
  }
}

/// Set the capability manifest for an agent.
/// Returns the updated state.
pub fn set_manifest(
  state: CapabilityManifestState,
  agent_id: String,
  manifest: CapabilityManifest,
) -> CapabilityManifestState {
  CapabilityManifestState(
    ..state,
    manifests: dict.insert(state.manifests, agent_id, manifest),
  )
}

/// Check if a tool is allowed for an agent.
/// Combines for_agent + allowed into a single operation.
pub fn agent_allowed(
  state: CapabilityManifestState,
  agent_id: String,
  tool_name: String,
) -> Bool {
  let manifest = for_agent(state, agent_id)
  allowed(manifest, tool_name)
}

/// Remove a manifest for an agent (reset to default).
pub fn remove_manifest(
  state: CapabilityManifestState,
  agent_id: String,
) -> CapabilityManifestState {
  CapabilityManifestState(
    ..state,
    manifests: dict.delete(state.manifests, agent_id),
  )
}

/// Add an allowed tool to an agent's manifest.
pub fn allow_tool(
  state: CapabilityManifestState,
  agent_id: String,
  tool_name: String,
) -> CapabilityManifestState {
  let manifest = for_agent(state, agent_id)
  let new_manifest =
    CapabilityManifest(..manifest, allowed_tools: [
      tool_name,
      ..manifest.allowed_tools
    ])
  CapabilityManifestState(
    ..state,
    manifests: dict.insert(state.manifests, agent_id, new_manifest),
  )
}

/// Add a denied tool to an agent's manifest.
pub fn deny_tool(
  state: CapabilityManifestState,
  agent_id: String,
  tool_name: String,
) -> CapabilityManifestState {
  let manifest = for_agent(state, agent_id)
  let new_manifest =
    CapabilityManifest(..manifest, denied_tools: [
      tool_name,
      ..manifest.denied_tools
    ])
  CapabilityManifestState(
    ..state,
    manifests: dict.insert(state.manifests, agent_id, new_manifest),
  )
}

/// List all allowed tools for an agent.
pub fn list_allowed(
  state: CapabilityManifestState,
  agent_id: String,
) -> List(String) {
  let manifest = for_agent(state, agent_id)
  manifest.allowed_tools
}

/// List all denied tools for an agent.
pub fn list_denied(
  state: CapabilityManifestState,
  agent_id: String,
) -> List(String) {
  let manifest = for_agent(state, agent_id)
  manifest.denied_tools
}
