import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import supernova/self/constellation

pub fn main() -> Nil {
  gleeunit.main()
}

fn fixture() -> String {
  let assert Ok(raw) = read("test/fixtures/constellation_small.json")
  raw
}

pub fn valid_constellation_loads_test() {
  let assert Ok(constellation) = constellation.parse(fixture())
  constellation.version |> should.equal(1)
  constellation.dimensions |> list.length |> should.equal(5)
  constellation.traits |> list.length |> should.equal(23)
  constellation.affinity_weight(constellation, "temp_0", "voz_0")
  |> should.equal(0.8)
  constellation.affinity_weight(constellation, "voz_0", "temp_0")
  |> should.equal(0.8)
}

pub fn unknown_dimension_is_rejected_test() {
  let raw =
    string.replace(
      fixture(),
      "\"dimension\": \"temperamento\"",
      "\"dimension\": \"nope\"",
    )
  let assert Error(reason) = constellation.parse(raw)
  string.contains(reason, "unknown dimension") |> should.be_true()
}

pub fn duplicate_trait_is_rejected_test() {
  let raw =
    string.replace(fixture(), "\"id\": \"temp_1\"", "\"id\": \"temp_0\"")
  let assert Error(reason) = constellation.parse(raw)
  string.contains(reason, "duplicate trait") |> should.be_true()
}

pub fn unknown_affinity_trait_is_rejected_test() {
  let raw = string.replace(fixture(), "\"a\": \"temp_0\"", "\"a\": \"ghost\"")
  let assert Error(reason) = constellation.parse(raw)
  string.contains(reason, "unknown trait") |> should.be_true()
}

pub fn out_of_range_affinity_is_rejected_test() {
  let raw = string.replace(fixture(), "\"weight\": 0.8", "\"weight\": 1.8")
  let assert Error(reason) = constellation.parse(raw)
  string.contains(reason, "out of range") |> should.be_true()
}

pub fn pick_above_dimension_size_is_rejected_test() {
  let raw = string.replace(fixture(), "\"pick\": 2", "\"pick\": 99")
  let assert Error(reason) = constellation.parse(raw)
  string.contains(reason, "pick exceeds") |> should.be_true()
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read(path: String) -> Result(String, String)
