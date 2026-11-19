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

pub fn same_origin_pressures_diminish_test() {
  let now = 100 * day
  let pressures = [
    pressure(now, "sim:alice", 1.0),
    pressure(now, "sim:alice", 1.0),
    pressure(now, "sim:alice", 1.0),
    pressure(now, "sim:alice", 1.0),
    pressure(now, "sim:alice", 1.0),
  ]
  let value = drift.effective_for(pressures, "curiosa", "cauta", now, 30.0)
  { value <. 2.3 } |> should.be_true()
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
    )
  drift.eligible_at(0, 0, 89 * day, drift_config) |> should.equal(False)
  drift.eligible_at(0, 0, 90 * day, drift_config) |> should.equal(True)
  drift.eligible_at(0, 100 * day, 120 * day, drift_config)
  |> should.equal(False)
}
