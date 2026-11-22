import gleam/list
import gleeunit/should
import supernova/core

pub fn core_facade_version_test() {
  core.version()
  |> should.equal("1.0.0")
}

pub fn core_facade_capabilities_not_empty_test() {
  core.capabilities()
  |> list.length
  |> should.equal(23)
}
