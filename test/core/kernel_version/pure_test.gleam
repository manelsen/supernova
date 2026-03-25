//// KernelVersion — Pure Tests
////
//// Tests for pure functions in the kernel version API.

import gleam/list
import gleeunit/should
import supernova/core/kernel_version/pure
import supernova/core/kernel_version/types

// ============================================================================
// Version Tests
// ============================================================================

pub fn get_version_test() {
  let version = pure.get_version()
  version.major |> should.equal(1)
  version.minor |> should.equal(0)
  version.patch |> should.equal(0)
}

pub fn current_version_constant_test() {
  pure.current_version.major |> should.equal(1)
  pure.current_version.minor |> should.equal(0)
  pure.current_version.patch |> should.equal(0)
}

pub fn version_result_ok_test() {
  let version = types.KernelVersion(major: 1, minor: 0, patch: 0)
  let result = pure.version_result(version)
  case result {
    types.KernelVersionOk(data) -> data |> should.equal("1.0.0")
    types.KernelVersionError(_) -> panic as "Expected Ok but got Error"
  }
}

pub fn error_result_test() {
  let result = pure.error_result("something went wrong")
  case result {
    types.KernelVersionOk(_) -> panic as "Expected Error but got Ok"
    types.KernelVersionError(msg) -> msg |> should.equal("something went wrong")
  }
}

// ============================================================================
// Capabilities Tests
// ============================================================================

pub fn get_all_capabilities_not_empty_test() {
  let caps = pure.get_all_capabilities()
  caps |> list.is_empty |> should.equal(False)
}

pub fn get_enabled_capabilities_test() {
  let enabled = pure.get_enabled_capabilities()
  let disabled = list.filter(enabled, fn(c) { !c.enabled })
  disabled |> list.is_empty |> should.equal(True)
}

pub fn get_enabled_capability_names_not_empty_test() {
  let names = pure.get_enabled_capability_names()
  names |> list.is_empty |> should.equal(False)
}

pub fn get_enabled_capability_names_contains_kernel_api_test() {
  let names = pure.get_enabled_capability_names()
  list.contains(names, "kernel_api") |> should.be_true
}

pub fn get_enabled_capability_names_contains_resource_ledger_test() {
  let names = pure.get_enabled_capability_names()
  list.contains(names, "resource_ledger") |> should.be_true
}

pub fn get_enabled_capability_names_contains_world_model_test() {
  let names = pure.get_enabled_capability_names()
  list.contains(names, "world_model") |> should.be_true
}

pub fn capabilities_result_ok_test() {
  let names = ["resource_ledger", "world_model", "kernel_api"]
  let result = pure.capabilities_result(names)
  case result {
    types.KernelVersionOk(data) -> {
      data
      |> should.equal("[\"resource_ledger\",\"world_model\",\"kernel_api\"]")
    }
    types.KernelVersionError(_) -> panic as "Expected Ok but got Error"
  }
}

pub fn capabilities_result_empty_test() {
  let result = pure.capabilities_result([])
  case result {
    types.KernelVersionOk(data) -> data |> should.equal("[]")
    types.KernelVersionError(_) -> panic as "Expected Ok but got Error"
  }
}

// ============================================================================
// Type Formatting Tests
// ============================================================================

pub fn version_to_string_test() {
  let version = types.KernelVersion(major: 1, minor: 2, patch: 3)
  types.version_to_string(version) |> should.equal("1.2.3")
}

pub fn version_to_string_zero_test() {
  let version = types.KernelVersion(major: 0, minor: 0, patch: 0)
  types.version_to_string(version) |> should.equal("0.0.0")
}

pub fn format_capabilities_empty_test() {
  types.format_capabilities([]) |> should.equal("[]")
}

pub fn format_capabilities_single_test() {
  types.format_capabilities(["resource_ledger"])
  |> should.equal("[\"resource_ledger\"]")
}

pub fn format_capabilities_multiple_test() {
  types.format_capabilities(["a", "b", "c"])
  |> should.equal("[\"a\",\"b\",\"c\"]")
}

pub fn all_tool_names_test() {
  let names = types.all_tool_names()
  list.length(names) |> should.equal(2)
  list.contains(names, "kernel.version") |> should.be_true
  list.contains(names, "kernel.capabilities") |> should.be_true
}
