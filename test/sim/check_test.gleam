import gleam/list
import gleeunit
import gleeunit/should
import supernova/sim/check

pub fn main() -> Nil {
  gleeunit.main()
}

const data_dir = "test/fixtures/b2_e2e_data"

const transcripts = "test/fixtures/b2_e2e_transcripts.jsonl"

pub fn recorded_e2e_evidence_has_no_violations_test() {
  check.evaluate(
    data_dir,
    transcripts,
    5.0,
    1.0,
    ["sim:alice", "sim:bob"],
    "Esta instância é privada.",
  )
  |> should.equal([])
}

pub fn mismatched_denial_text_reports_i2_test() {
  let violations =
    check.evaluate(
      data_dir,
      transcripts,
      5.0,
      1.0,
      ["sim:alice", "sim:bob"],
      "Esta instância é privada.",
    )
  violations |> list.is_empty |> should.be_true()

  // The fixture's secret belongs to sim:alice; a prompt for sim:bob carrying
  // it must be detected by the same decoder path.
  check.evaluate(
    data_dir,
    "test/fixtures/b2_e2e_transcripts.jsonl",
    5.0,
    1.0,
    ["sim:alice", "sim:bob"],
    "outra negação",
  )
  |> list.any(fn(violation) { violation.invariant == "I2" })
  |> should.be_true()
}
