import gleam/list
import gleeunit
import gleeunit/should
import supernova/sim/check
import supernova/sim/invariants

pub fn main() -> Nil {
  gleeunit.main()
}

const data_dir = "test/fixtures/b2_e2e_data"

const transcripts = "test/fixtures/b2_e2e_transcripts.jsonl"

const bad_data_dir = "test/fixtures/b2_c07_bad_data"

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

pub fn phase_c_evidence_has_no_violations_test() {
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

pub fn violating_phase_c_evidence_reports_i7_i8_i9_test() {
  let violations =
    check.evaluate(
      bad_data_dir,
      transcripts,
      5.0,
      1.0,
      ["sim:alice", "sim:bob"],
      "Esta instância é privada.",
    )

  violations
  |> list.filter(fn(violation) { violation.invariant == "I7" })
  |> should.equal([
    invariants.Violation("I7", "core.md hash mismatch for sim:alice"),
    invariants.Violation("I7", "missing drift for gentil of sim:bob"),
  ])

  violations
  |> list.filter(fn(violation) { violation.invariant == "I8" })
  |> should.equal([
    invariants.Violation(
      "I8",
      "successful tool_call on agents/sim_alice/self/core.md for sim:alice",
    ),
  ])

  violations
  |> list.filter(fn(violation) { violation.invariant == "I9" })
  |> should.equal([
    invariants.Violation(
      "I9",
      "journal entry from sim:alice survived forget at 1000",
    ),
    invariants.Violation(
      "I9",
      "experience entry from sim:alice survived forget at 1000",
    ),
    invariants.Violation(
      "I9",
      "pressure entry from sim:alice survived forget at 1000",
    ),
  ])
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
