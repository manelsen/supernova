import gleeunit
import gleeunit/should
import supernova/wizard_main

pub fn main() {
  gleeunit.main()
}

@external(erlang, "supernova_wizard_ffi", "set_test_inputs")
fn set_test_inputs(inputs: List(String)) -> Nil

@external(erlang, "supernova_wizard_ffi", "set_test_write_error")
fn set_test_write_error(message: String) -> Nil

@external(erlang, "supernova_wizard_ffi", "clear_test_state")
fn clear_test_state() -> Nil

pub fn wizard_main_handles_user_cancel_test() {
  clear_test_state()
  set_test_inputs([])

  wizard_main.main() |> should.equal(Nil)
  clear_test_state()
}

pub fn wizard_main_handles_file_write_error_test() {
  clear_test_state()
  set_test_inputs([
    "wizard-main-app",
    "2",
    "telegram-token-xyz",
    "1",
    "",
    "",
    "1",
    "/tmp/supernova-wizard-main.yaml",
  ])
  set_test_write_error("disk_full")

  wizard_main.main() |> should.equal(Nil)
  clear_test_state()
}
