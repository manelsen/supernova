import gleeunit/should
import supernova/core/budget_policy/actor as budget
import supernova/core/budget_policy/types.{BudgetConfig, BudgetTokens}
import supernova/harness/clock

// Regression from the first real battery: the hourly window followed the
// wall clock while the harness advanced simulated time, so the window never
// reset and every agent ended on "Seu limite de uso desta hora acabou".
pub fn hourly_window_follows_the_injected_clock_test() {
  let assert Ok(time) = clock.start(1_000_000)
  let config =
    BudgetConfig(
      tokens_per_hour: 1000,
      tool_calls_per_minute: -1,
      tool_calls_per_hour: -1,
      max_recursion_depth: 5,
      max_sub_agents: 10,
    )
  let assert Ok(policy) =
    budget.start_with_config_and_clock(config, 20, clock.as_fn(time))
  budget.record_consumption(policy, "sim:a", BudgetTokens, 1000)
  budget.check(policy, "sim:a", BudgetTokens, 10) |> should.be_error()
  let _ = clock.advance(time, 3_600_001)
  budget.check(policy, "sim:a", BudgetTokens, 10) |> should.be_ok()
  budget.stop(policy)
  clock.stop(time)
}
