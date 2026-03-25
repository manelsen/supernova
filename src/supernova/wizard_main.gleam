//// Entry point for the setup wizard.
////
//// Run with:
////
////   gleam run -m supernova/wizard_main

import gleam/io
import supernova/wizard

/// Runs the interactive setup wizard module entrypoint.
pub fn main() -> Nil {
  case wizard.run() {
    Ok(_) -> Nil
    Error(wizard.UserCancelled) -> io.println("\nSetup cancelled.")
    Error(wizard.FileWriteError(msg)) ->
      io.println("Error writing config: " <> msg)
  }
}
