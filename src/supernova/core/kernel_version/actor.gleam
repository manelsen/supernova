//// KernelVersion — Actor
////
//// OTP actor for kernel version API.
//// Provides tools for agents to query:
//// - kernel.version: the syscall interface version
//// - kernel.capabilities: list of enabled kernel capabilities
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(version_api) = actor.start()
//// let result = actor.handle_version(version_api)
//// let caps = actor.handle_capabilities(version_api)
//// actor.stop(version_api)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import supernova/core/kernel_version/pure
import supernova/core/kernel_version/types.{type KernelVersionResult}
import supernova/llm/provider

// ============================================================================
// Types
// ============================================================================

/// Messages handled by the kernel version actor.
pub type KernelVersionMessage {
  GetVersion(reply_to: Subject(KernelVersionResult))
  GetCapabilities(reply_to: Subject(KernelVersionResult))
  GetToolDefinitions(reply_to: Subject(List(provider.ToolDefinition)))
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running kernel version actor.
pub type KernelVersionHandle =
  Subject(KernelVersionMessage)

// ============================================================================
// Tool Definitions
// ============================================================================

/// Get the tool definition for kernel.version.
pub fn kernel_version_tool() -> provider.ToolDefinition {
  provider.new_tool(
    "kernel.version",
    "Get the semantic version of the kernel syscall interface. Returns version string in format MAJOR.MINOR.PATCH. Agents should query this to understand what features are available.",
    [],
  )
}

/// Get the tool definition for kernel.capabilities.
pub fn kernel_capabilities_tool() -> provider.ToolDefinition {
  provider.new_tool(
    "kernel.capabilities",
    "Get the list of enabled kernel capabilities in this Supernova runtime. Returns a JSON array of capability names like [\"resource_ledger\", \"world_model\", \"kernel_api\"].",
    [],
  )
}

/// Get all kernel version tool definitions.
pub fn all_tool_definitions() -> List(provider.ToolDefinition) {
  [kernel_version_tool(), kernel_capabilities_tool()]
}

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  _state: Nil,
  message: KernelVersionMessage,
) -> actor.Next(Nil, KernelVersionMessage) {
  case message {
    GetVersion(reply_to) -> {
      let result = pure.version_result(pure.get_version())
      actor.send(reply_to, result)
      actor.continue(Nil)
    }

    GetCapabilities(reply_to) -> {
      let result = pure.capabilities_result(pure.get_enabled_capability_names())
      actor.send(reply_to, result)
      actor.continue(Nil)
    }

    GetToolDefinitions(reply_to) -> {
      actor.send(reply_to, all_tool_definitions())
      actor.continue(Nil)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start the kernel version actor.
pub fn start() -> Result(KernelVersionHandle, actor.StartError) {
  case actor.new(Nil) |> actor.on_message(handle_message) |> actor.start {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Handle a GetVersion request synchronously.
pub fn handle_version(api: KernelVersionHandle) -> KernelVersionResult {
  actor.call(api, waiting: 5000, sending: GetVersion)
}

/// Handle a GetCapabilities request synchronously.
pub fn handle_capabilities(api: KernelVersionHandle) -> KernelVersionResult {
  actor.call(api, waiting: 5000, sending: GetCapabilities)
}

/// Get all tool definitions synchronously.
pub fn handle_tool_definitions(
  api: KernelVersionHandle,
) -> List(provider.ToolDefinition) {
  actor.call(api, waiting: 5000, sending: GetToolDefinitions)
}

/// Stop the actor.
pub fn stop(api: KernelVersionHandle) -> Nil {
  actor.call(api, waiting: 5000, sending: Stop)
}

// ============================================================================
// Tool Definitions Helpers (for tool registry)
// ============================================================================

/// Get the tool definitions - this is a simple getter, no async needed.
pub fn get_tool_definitions() -> List(provider.ToolDefinition) {
  all_tool_definitions()
}
