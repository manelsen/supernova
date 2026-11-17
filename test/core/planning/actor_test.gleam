import gleam/otp/actor
import gleam/string
import gleeunit
import gleeunit/should
import supernova/core/planning/actor as planning_actor
import supernova/core/planning/types as planning_types

pub fn main() {
  gleeunit.main()
}

pub fn start_and_stop_planning_actor_test() {
  let assert Ok(planner) = planning_actor.start()
  actor.call(planner, waiting: 1000, sending: planning_actor.Stop)
  |> should.equal(Nil)
}

pub fn plan_without_api_key_returns_planning_error_test() {
  let assert Ok(planner) = planning_actor.start()

  case planning_actor.plan(planner, "Decompose a task", "agent-1") {
    planning_types.PlanningError(reason) ->
      string.contains(reason, "No API key configured for zhipu")
      |> should.equal(True)
    planning_types.PlanningSuccess(_) ->
      panic as "Expected planning error when no Zhipu API key is configured"
  }

  actor.call(planner, waiting: 1000, sending: planning_actor.Stop)
  |> should.equal(Nil)
}
