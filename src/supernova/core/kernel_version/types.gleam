//// KernelVersion — Pure Types
////
//// Pure types for kernel version and capabilities API.
//// No FFI, no side effects.
////
//// Provides:
//// - version(): returns the syscall interface version (semantic version string)
//// - capabilities(): returns list of enabled kernel capabilities

import gleam/int
import gleam/list
import gleam/string

// ============================================================================
// Kernel Version Types
// ============================================================================

/// The semantic version of the syscall interface.
/// Follows semver: MAJOR.MINOR.PATCH
pub type KernelVersion {
  KernelVersion(major: Int, minor: Int, patch: Int)
}

/// Result of a kernel version operation.
pub type KernelVersionResult {
  /// Operation succeeded
  KernelVersionOk(data: String)
  /// Operation failed
  KernelVersionError(message: String)
}

// ============================================================================
// Capabilities Types
// ============================================================================

/// Represents a capability that may or may not be enabled.
pub type Capability {
  Capability(name: String, enabled: Bool)
}

// ============================================================================
// Tool Definitions
// ============================================================================

/// Name of the kernel version tool.
pub const kernel_version_tool: String = "kernel.version"

/// Name of the kernel capabilities tool.
pub const kernel_capabilities_tool: String = "kernel.capabilities"

/// All kernel version tool names.
pub fn all_tool_names() -> List(String) {
  [kernel_version_tool, kernel_capabilities_tool]
}

// ============================================================================
// Formatting Helpers
// ============================================================================

/// Format a KernelVersion as a semver string (e.g., "1.0.0").
pub fn version_to_string(version: KernelVersion) -> String {
  int.to_string(version.major)
  <> "."
  <> int.to_string(version.minor)
  <> "."
  <> int.to_string(version.patch)
}

/// Format a list of capability names as a JSON array string.
pub fn format_capabilities(capabilities: List(String)) -> String {
  case capabilities {
    [] -> "[]"
    _ -> {
      let items = list.map(capabilities, fn(c) { "\"" <> c <> "\"" })
      "[" <> string.join(items, ",") <> "]"
    }
  }
}
