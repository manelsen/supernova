//// Channel readiness is reported by the channels themselves.

import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import supernova/channel/health
import supernova/health/types as health_types

fn find(statuses: List(health_types.ChannelStatus), name: String) {
  let assert Ok(status) = list.find(statuses, fn(s) { s.name == name })
  status
}

pub fn started_channel_without_silence_limit_stays_ready_test() {
  let h = health.start()
  health.started(h, "discord", None, 0)
  let status = find(health.snapshot(h, 999_999_999), "discord")
  status.ready |> should.be_true()
  status.error |> should.equal(None)
}

pub fn failed_start_is_not_ready_test() {
  let h = health.start()
  health.failed(h, "matrix", "bad token")
  let status = find(health.snapshot(h, 0), "matrix")
  status.ready |> should.be_false()
  status.error |> should.equal(Some("bad token"))
}

pub fn error_report_then_success_recovers_test() {
  let h = health.start()
  health.started(h, "telegram", Some(60_000), 0)
  health.report(h, "telegram", Error("telegram api error 401"), 1000)
  let status = find(health.snapshot(h, 1000), "telegram")
  status.ready |> should.be_false()
  status.error |> should.equal(Some("telegram api error 401"))
  health.report(h, "telegram", Ok(Nil), 2000)
  find(health.snapshot(h, 2000), "telegram").ready |> should.be_true()
}

pub fn silence_beyond_limit_is_not_ready_test() {
  let h = health.start()
  health.started(h, "telegram", Some(60_000), 0)
  find(health.snapshot(h, 60_000), "telegram").ready |> should.be_true()
  let status = find(health.snapshot(h, 60_001), "telegram")
  status.ready |> should.be_false()
  status.error |> should.equal(Some("no successful poll for 60s"))
}

pub fn snapshot_is_sorted_by_name_test() {
  let h = health.start()
  health.started(h, "telegram", None, 0)
  health.started(h, "discord", None, 0)
  health.snapshot(h, 0)
  |> list.map(fn(s) { s.name })
  |> should.equal(["discord", "telegram"])
}
