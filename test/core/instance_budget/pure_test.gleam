import gleeunit/should
import supernova/core/instance_budget/pure

pub fn cap_is_raised_only_for_the_current_day_test() {
  let state = pure.new("2026-11-18")
  let raised = pure.raise_cap(state, "2026-11-18", 20.0)
  pure.effective_cap(5.0, raised, "2026-11-18") |> should.equal(25.0)
  pure.effective_cap(5.0, raised, "2026-11-19") |> should.equal(5.0)
}

pub fn raises_accumulate_on_the_same_day_test() {
  let state = pure.new("2026-11-18")
  let once = pure.raise_cap(state, "2026-11-18", 10.0)
  let twice = pure.raise_cap(once, "2026-11-18", 5.0)
  pure.effective_cap(5.0, twice, "2026-11-18") |> should.equal(20.0)
}

pub fn unlimited_cap_stays_unlimited_test() {
  pure.effective_cap(-1.0, pure.new("2026-11-18"), "2026-11-18")
  |> should.equal(-1.0)
  pure.reached(1_000_000.0, -1.0) |> should.equal(False)
}

pub fn reached_and_percentage_test() {
  pure.reached(4.99, 5.0) |> should.equal(False)
  pure.reached(5.0, 5.0) |> should.equal(True)
  pure.percentage(4.0, 5.0) |> should.equal(80.0)
  pure.percentage(1.0, -1.0) |> should.equal(0.0)
}
