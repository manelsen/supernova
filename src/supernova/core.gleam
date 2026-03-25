//// Core module for Supernova
//// This module contains the main business logic and abstractions.

import supernova/core/kernel_version/pure as kernel_version_pure
import supernova/core/kernel_version/types as kernel_version_types

/// Return current kernel version as semantic string.
pub fn version() -> String {
  kernel_version_pure.get_version()
  |> kernel_version_pure.version_result
  |> version_result_to_string
}

/// Return enabled kernel capability names.
pub fn capabilities() -> List(String) {
  kernel_version_pure.get_enabled_capability_names()
}

fn version_result_to_string(
  result: kernel_version_types.KernelVersionResult,
) -> String {
  case result {
    kernel_version_types.KernelVersionOk(value) -> value
    kernel_version_types.KernelVersionError(message) -> "error:" <> message
  }
}
