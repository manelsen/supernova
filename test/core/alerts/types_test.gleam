import gleeunit
import gleeunit/should
import supernova/core/alerts/types

pub fn main() {
  gleeunit.main()
}

pub fn alert_type_and_severity_roundtrip_test() {
  types.alert_type_to_string(types.BudgetWarning)
  |> should.equal("budget_warning")
  types.alert_type_to_string(types.StallWarning)
  |> should.equal("stall_warning")
  types.alert_type_to_string(types.LLMFailureChain)
  |> should.equal("llm_failure_chain")

  types.severity_to_string(types.Info) |> should.equal("info")
  types.severity_to_string(types.Warning) |> should.equal("warning")
  types.severity_to_string(types.Critical) |> should.equal("critical")

  types.string_to_alert_type("budget_warning")
  |> should.equal(Ok(types.BudgetWarning))
  types.string_to_alert_type("stall_warning")
  |> should.equal(Ok(types.StallWarning))
  types.string_to_alert_type("llm_failure_chain")
  |> should.equal(Ok(types.LLMFailureChain))

  types.string_to_severity("info") |> should.equal(Ok(types.Info))
  types.string_to_severity("warning") |> should.equal(Ok(types.Warning))
  types.string_to_severity("critical") |> should.equal(Ok(types.Critical))
}

pub fn unknown_alert_type_and_severity_return_errors_test() {
  types.string_to_alert_type("unknown")
  |> should.equal(Error(types.InvalidAlert("Unknown alert type: unknown")))

  types.string_to_severity("unknown")
  |> should.equal(Error(types.InvalidAlert("Unknown severity: unknown")))
}
