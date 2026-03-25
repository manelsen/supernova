//// KernelVersion — Pure Functions
////
//// Pure functions for kernel version API.
//// No FFI, no side effects.
////
//// ## Usage
////
//// ```gleam
//// let version = pure.get_version()
//// let caps = pure.get_capabilities()
//// let result = pure.version_result(version)
//// ```

import gleam/list
import supernova/core/kernel_version/types

// ============================================================================
// Version
// ============================================================================

/// The current syscall interface version.
/// This is the version agents should query to understand what features
/// are available in this kernel.
pub const current_version: types.KernelVersion = types.KernelVersion(
  major: 1,
  minor: 0,
  patch: 0,
)

/// Get the current kernel version.
pub fn get_version() -> types.KernelVersion {
  current_version
}

/// Format version result as a KernelVersionResult.
pub fn version_result(version: types.KernelVersion) -> types.KernelVersionResult {
  types.KernelVersionOk(types.version_to_string(version))
}

/// Format an error as a KernelVersionResult.
pub fn error_result(message: String) -> types.KernelVersionResult {
  types.KernelVersionError(message)
}

// ============================================================================
// Capabilities
// ============================================================================

/// List of all capabilities that can be enabled in the Supernova kernel.
/// Each capability corresponds to a user story that has been implemented.
const all_capabilities: List(types.Capability) = [
  types.Capability(name: "resource_ledger", enabled: True),
  types.Capability(name: "world_model", enabled: True),
  types.Capability(name: "memory", enabled: True),
  types.Capability(name: "memory_recall", enabled: True),
  types.Capability(name: "llm_streaming", enabled: True),
  types.Capability(name: "sub_agents", enabled: True),
  types.Capability(name: "mcp", enabled: True),
  types.Capability(name: "entry_point", enabled: True),
  types.Capability(name: "budget_policy", enabled: True),
  types.Capability(name: "telemetry", enabled: True),
  types.Capability(name: "workspace_policy", enabled: True),
  types.Capability(name: "capability_manifest", enabled: True),
  types.Capability(name: "audit_log", enabled: True),
  types.Capability(name: "agent_queue", enabled: True),
  types.Capability(name: "kernel_scheduler", enabled: True),
  types.Capability(name: "checkpoint", enabled: True),
  types.Capability(name: "task_graph", enabled: True),
  types.Capability(name: "dag_tasks", enabled: True),
  types.Capability(name: "typed_subagent_result", enabled: True),
  types.Capability(name: "memory_federation", enabled: True),
  types.Capability(name: "context_injector", enabled: True),
  types.Capability(name: "syscall", enabled: True),
  types.Capability(name: "kernel_api", enabled: True),
  types.Capability(name: "kernel_version", enabled: True),
]

/// Get all capabilities (enabled and disabled).
pub fn get_all_capabilities() -> List(types.Capability) {
  all_capabilities
}

/// Get only enabled capabilities.
pub fn get_enabled_capabilities() -> List(types.Capability) {
  list.filter(all_capabilities, fn(c) { c.enabled })
}

/// Get the names of all enabled capabilities.
pub fn get_enabled_capability_names() -> List(String) {
  list.map(get_enabled_capabilities(), fn(c) { c.name })
}

/// Format capabilities result as a KernelVersionResult.
pub fn capabilities_result(
  capability_names: List(String),
) -> types.KernelVersionResult {
  types.KernelVersionOk(types.format_capabilities(capability_names))
}
