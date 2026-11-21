import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import supernova/config
import supernova/self/drift
import supernova/self/memory

const day = 86_400_000

fn pressure(at: Int, origin: String, strength: Float) -> memory.Pressure {
  memory.Pressure(
    at: at,
    origin: origin,
    from: "curiosa",
    to: "cauta",
    strength: strength,
    reason: "teste",
  )
}

pub fn decay_is_half_after_one_half_life_test() {
  let now = 100 * day
  drift.effective_for(
    [pressure(now - 30 * day, "sim:alice", 1.0)],
    "curiosa",
    "cauta",
    now,
    30.0,
  )
  |> should.equal(0.5)
}

// Persistence changes a self, not volume: five pressures on one day sum, but
// they are one day.
pub fn pressures_on_one_day_are_one_day_test() {
  let now = 100 * day
  let pressures = [
    pressure(now, "sim:alice", 1.0),
    pressure(now, "sim:alice", 1.0),
    pressure(now, "sim:alice", 1.0),
    pressure(now, "sim:alice", 1.0),
    pressure(now, "sim:alice", 1.0),
  ]
  drift.effective_for(pressures, "curiosa", "cauta", now, 30.0)
  |> should.equal(5.0)
  drift.pressure_days(pressures, "curiosa", "cauta", now, 30.0)
  |> should.equal(1)
  drift.above_threshold(pressures, now, config.default_drift_config())
  |> should.equal(None)
}

fn weekly(weeks: Int, strength: Float) -> List(memory.Pressure) {
  int.range(from: 0, to: weeks, with: [], run: fn(acc, week) {
    [pressure(week * 7 * day, "sim:alice", strength), ..acc]
  })
  |> list.reverse
}

// Maintainer decision: a month of living is enough for a nudge. The
// reflection writes pressures of 0.25; weekly, they cross on the sixth, five
// weeks after the first.
pub fn weekly_pressure_nudges_after_five_weeks_test() {
  let drift_config = config.default_drift_config()
  drift.above_threshold(weekly(5, 0.25), 4 * 7 * day, drift_config)
  |> should.equal(None)
  let assert Some(_) =
    drift.above_threshold(weekly(6, 0.25), 5 * 7 * day, drift_config)
}

// One strong push, or a burst, is never enough.
pub fn a_single_strong_pressure_never_changes_the_self_test() {
  let drift_config = config.default_drift_config()
  drift.above_threshold(
    [pressure(10 * day, "sim:alice", 1.0)],
    10 * day,
    drift_config,
  )
  |> should.equal(None)
  drift.above_threshold(
    [
      pressure(10 * day, "sim:alice", 1.0),
      pressure(11 * day, "sim:alice", 1.0),
      pressure(12 * day, "sim:alice", 1.0),
    ],
    12 * day,
    drift_config,
  )
  |> should.equal(None)
}

pub fn different_origins_do_not_diminish_test() {
  let now = 100 * day
  let pressures = [
    pressure(now, "sim:alice", 1.0),
    pressure(now, "sim:bob", 1.0),
    pressure(now, "sim:carol", 1.0),
    pressure(now, "sim:dave", 1.0),
    pressure(now, "sim:erin", 1.0),
  ]
  drift.effective_for(pressures, "curiosa", "cauta", now, 30.0)
  |> should.equal(5.0)
}

pub fn min_interval_respects_birth_and_last_change_test() {
  let drift_config =
    config.DriftConfig(
      half_life_days: 30.0,
      threshold: 3.0,
      min_interval_days: 90,
      min_pressure_days: 4,
    )
  drift.eligible_at(0, 0, 89 * day, drift_config) |> should.equal(False)
  drift.eligible_at(0, 0, 90 * day, drift_config) |> should.equal(True)
  drift.eligible_at(0, 100 * day, 120 * day, drift_config)
  |> should.equal(False)
}

// From review: zero-strength records counted as days of pressure, so one
// real push after three empty ones was "persistent".
pub fn zero_strength_days_do_not_count_test() {
  let pressures = [
    pressure(1 * day, "sim:alice", 0.0),
    pressure(2 * day, "sim:alice", 0.0),
    pressure(3 * day, "sim:alice", 0.0),
    pressure(4 * day, "sim:alice", 1.0),
  ]
  drift.pressure_days(pressures, "curiosa", "cauta", 4 * day, 30.0)
  |> should.equal(1)
  drift.above_threshold(pressures, 4 * day, config.default_drift_config())
  |> should.equal(None)
}
