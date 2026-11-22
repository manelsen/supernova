//// KernelVersion — Actor Tests
////
//// Tests for the kernel version actor.

import gleam/list
import gleeunit/should
import supernova/core/kernel_version/actor
import supernova/core/kernel_version/types

// ============================================================================
// Actor Start/Stop Tests
// ============================================================================

pub fn start_success_test() {
  let result = actor.start()
  result |> should.be_ok
}

pub fn stop_after_start_test() {
  let assert Ok(api) = actor.start()
  actor.stop(api)
  // If we get here without crashing, the test passes
}

// ============================================================================
// GetVersion Tests
// ============================================================================

pub fn get_version_returns_ok_test() {
  let assert Ok(api) = actor.start()
  let result = actor.handle_version(api)
  case result {
    types.KernelVersionOk(_) -> True
    types.KernelVersionError(_) -> panic as "Expected Ok but got Error"
  }
  actor.stop(api)
}

pub fn get_version_returns_valid_semver_test() {
  let assert Ok(api) = actor.start()
  let assert types.KernelVersionOk(data) = actor.handle_version(api)
  // Should be in format "MAJOR.MINOR.PATCH"
  data |> should.equal("1.0.0")
  actor.stop(api)
}

// ============================================================================
// GetCapabilities Tests
// ============================================================================

pub fn get_capabilities_returns_ok_test() {
  let assert Ok(api) = actor.start()
  let result = actor.handle_capabilities(api)
  case result {
    types.KernelVersionOk(_) -> True
    types.KernelVersionError(_) -> panic as "Expected Ok but got Error"
  }
  actor.stop(api)
}

pub fn get_capabilities_returns_json_array_test() {
  let assert Ok(api) = actor.start()
  let assert types.KernelVersionOk(data) = actor.handle_capabilities(api)
  // Should start with [ and end with ]
  data
  |> should.equal(
    "[\"resource_ledger\",\"world_model\",\"memory\",\"llm_streaming\",\"sub_agents\",\"mcp\",\"entry_point\",\"budget_policy\",\"telemetry\",\"workspace_policy\",\"capability_manifest\",\"audit_log\",\"agent_queue\",\"kernel_scheduler\",\"checkpoint\",\"task_graph\",\"dag_tasks\",\"typed_subagent_result\",\"memory_federation\",\"context_injector\",\"syscall\",\"kernel_api\",\"kernel_version\"]",
  )
  actor.stop(api)
}

// ============================================================================
// GetToolDefinitions Tests
// ============================================================================

pub fn get_tool_definitions_returns_list_test() {
  let assert Ok(api) = actor.start()
  let tools = actor.handle_tool_definitions(api)
  list.length(tools) |> should.equal(2)
  actor.stop(api)
}

pub fn get_tool_definitions_contains_kernel_version_test() {
  let assert Ok(api) = actor.start()
  let tools = actor.handle_tool_definitions(api)
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "kernel.version") |> should.be_true
  actor.stop(api)
}

pub fn get_tool_definitions_contains_kernel_capabilities_test() {
  let assert Ok(api) = actor.start()
  let tools = actor.handle_tool_definitions(api)
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "kernel.capabilities") |> should.be_true
  actor.stop(api)
}

// ============================================================================
// Tool Definition Content Tests
// ============================================================================

pub fn kernel_version_tool_has_no_params_test() {
  let assert Ok(api) = actor.start()
  let tools = actor.handle_tool_definitions(api)
  let version_tool = list.find(tools, fn(t) { t.name == "kernel.version" })
  case version_tool {
    Ok(tool) -> tool.parameters |> should.equal([])
    Error(_) -> panic as "Expected to find kernel.version tool"
  }
  actor.stop(api)
}

// ============================================================================
// Static Tool Definitions Test
// ============================================================================

pub fn get_tool_definitions_static_test() {
  let tools = actor.get_tool_definitions()
  list.length(tools) |> should.equal(2)
}
