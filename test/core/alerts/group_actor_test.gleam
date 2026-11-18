import gleeunit/should
import supernova/core/alerts/group_actor
import supernova/core/alerts/group_pure

pub fn take_deduplicates_until_window_test() {
  let assert Ok(alerts) = group_actor.start()
  group_actor.take(alerts, group_pure.Budget80, "telegram:1", 1000)
  |> should.equal(True)
  group_actor.take(alerts, group_pure.Budget80, "telegram:1", 1000)
  |> should.equal(False)
  group_actor.take(alerts, group_pure.Instance100, "instance", 1000)
  |> should.equal(True)
  group_actor.stop(alerts)
}

pub fn abuse_alert_fires_after_six_denials_test() {
  let assert Ok(alerts) = group_actor.start()
  group_actor.record_denial(alerts, "telegram:999", 0) |> should.equal(False)
  group_actor.record_denial(alerts, "telegram:999", 1000) |> should.equal(False)
  group_actor.record_denial(alerts, "telegram:999", 2000) |> should.equal(False)
  group_actor.record_denial(alerts, "telegram:999", 3000) |> should.equal(False)
  group_actor.record_denial(alerts, "telegram:999", 4000) |> should.equal(False)
  group_actor.record_denial(alerts, "telegram:999", 5000) |> should.equal(True)
  group_actor.take(alerts, group_pure.Abuse, "telegram:999", 5000)
  |> should.equal(True)
  group_actor.stop(alerts)
}
