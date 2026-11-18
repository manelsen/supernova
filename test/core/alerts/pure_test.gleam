import gleam/dict
import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/alerts/pure
import supernova/core/alerts/types

pub fn main() {
  gleeunit.main()
}

pub fn create_budget_alert_thresholds_test() {
  pure.create_budget_alert("agent-1", 79, 100, 1000) |> should.equal(Error(Nil))
  pure.create_budget_alert("agent-1", 80, 100, 1000)
  |> should.be_ok()

  let assert Ok(alert) = pure.create_budget_alert("agent-1", 95, 100, 2000)
  alert.severity |> should.equal(types.Critical)
  dict.get(alert.context, "percentage") |> should.equal(Ok("95"))
}

pub fn create_stall_and_llm_failure_alert_test() {
  pure.create_stall_alert("agent-1", 1000, 2000) |> should.equal(Error(Nil))
  let assert Ok(stall) = pure.create_stall_alert("agent-1", 0, 3_600_000)
  stall.alert_type |> should.equal(types.StallWarning)

  pure.create_llm_failure_alert("agent-1", 2, 10_000)
  |> should.equal(Error(Nil))
  let assert Ok(chain) = pure.create_llm_failure_alert("agent-1", 3, 10_000)
  chain.alert_type |> should.equal(types.LLMFailureChain)
  chain.severity |> should.equal(types.Critical)
}

pub fn add_acknowledge_and_query_alerts_test() {
  let state = pure.initial_state_with_max(2)
  let assert Ok(first) = pure.create_budget_alert("agent-1", 90, 100, 1)
  let assert Ok(second) = pure.create_stall_alert("agent-2", 0, 3_700_000)
  let assert Ok(third) = pure.create_llm_failure_alert("agent-1", 5, 3)

  let #(state_1, commands_1) = pure.add_alert(state, first)
  list.length(commands_1) |> should.equal(2)
  pure.active_alert_count(state_1) |> should.equal(1)
  pure.alert_exists(state_1, "agent-1", types.BudgetWarning)
  |> should.equal(True)

  let #(state_2, _) = pure.add_alert(state_1, second)
  let #(state_3, _) = pure.add_alert(state_2, third)

  // max_alerts=2 should trim oldest alert
  pure.get_all_alerts(state_3) |> list.length() |> should.equal(2)
  pure.get_alerts_by_agent(state_3, "agent-1")
  |> list.length()
  |> should.equal(1)
  pure.get_alerts_by_type(state_3, types.LLMFailureChain)
  |> list.length()
  |> should.equal(1)

  let assert Ok(#(ack_state, _)) = pure.acknowledge(state_3, third.id)
  pure.active_alert_count(ack_state) |> should.equal(1)

  pure.acknowledge(ack_state, "missing-id")
  |> should.equal(Error(types.AlertNotFound("missing-id")))
}
