import gleeunit
import gleeunit/should
import supernova/core/alerts/actor as alerts_actor
import supernova/core/alerts/types
import supernova/core/kernel_scheduler/actor as scheduler_actor
import supernova/core/resource_ledger/actor as ledger_actor

pub fn main() {
  gleeunit.main()
}

pub fn alerts_actor_check_and_acknowledge_missing_test() {
  let assert Ok(alerts) = alerts_actor.start()
  let assert Ok(scheduler) = scheduler_actor.start()
  let assert Ok(ledger) = ledger_actor.start()

  alerts_actor.check(alerts, scheduler, ledger) |> should.equal(Ok([]))
  alerts_actor.get_active_alerts(alerts) |> should.equal([])
  alerts_actor.get_all_alerts(alerts) |> should.equal([])

  alerts_actor.acknowledge(alerts, "unknown-alert")
  |> should.equal(Error(types.AlertNotFound("unknown-alert")))

  alerts_actor.stop(alerts) |> should.equal(Nil)
  scheduler_actor.stop(scheduler) |> should.equal(Nil)
  ledger_actor.stop(ledger) |> should.equal(Nil)
}
