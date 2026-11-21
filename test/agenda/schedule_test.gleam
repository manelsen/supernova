import gleam/option.{None, Some}
import gleeunit/should
import supernova/agenda/schedule

// All times are in São Paulo (UTC−3). 2026-11-21 is a Saturday.
// 2026-11-21 12:00 local = 15:00 UTC.
const sat_noon = 1_795_273_200_000

const minute = 60_000

const hour = 3_600_000

const day = 86_400_000

const sp = -180

pub fn local_round_trip_test() {
  schedule.parse_local("2026-11-21 12:00", sp)
  |> should.equal(Ok(sat_noon))
}

pub fn daily_at_five_test() {
  let assert Ok(s) = schedule.parse("0 5 * * *", sat_noon, sp)
  // Next 05:00 after Saturday noon is Sunday 05:00.
  schedule.next_after(s, sat_noon, sp)
  |> should.equal(Some(sat_noon + 17 * hour))
}

pub fn same_day_later_test() {
  let assert Ok(s) = schedule.parse("30 18 * * *", sat_noon, sp)
  schedule.next_after(s, sat_noon, sp)
  |> should.equal(Some(sat_noon + 6 * hour + 30 * minute))
}

pub fn strictly_after_test() {
  let assert Ok(s) = schedule.parse("0 12 * * *", sat_noon, sp)
  schedule.next_after(s, sat_noon, sp)
  |> should.equal(Some(sat_noon + day))
}

pub fn weekdays_skip_weekend_test() {
  // Monday to Friday at 08:00: from Saturday noon, the next is Monday.
  let assert Ok(s) = schedule.parse("0 8 * * 1-5", sat_noon, sp)
  schedule.next_after(s, sat_noon, sp)
  |> should.equal(Some(sat_noon + 2 * day - 4 * hour))
}

pub fn sunday_as_seven_test() {
  let assert Ok(a) = schedule.parse("0 9 * * 0", sat_noon, sp)
  let assert Ok(b) = schedule.parse("0 9 * * 7", sat_noon, sp)
  schedule.next_after(a, sat_noon, sp)
  |> should.equal(schedule.next_after(b, sat_noon, sp))
}

pub fn list_and_step_test() {
  // Every three hours from 06:00, plus 23:00: after noon comes 15:00.
  let assert Ok(s) = schedule.parse("0 6-18/3,23 * * *", sat_noon, sp)
  schedule.next_after(s, sat_noon, sp)
  |> should.equal(Some(sat_noon + 3 * hour))
}

pub fn day_of_month_test() {
  // First of the month at 09:00: 2026-12-01.
  let assert Ok(s) = schedule.parse("0 9 1 * *", sat_noon, sp)
  schedule.next_after(s, sat_noon, sp)
  |> should.equal(Some(sat_noon + 10 * day - 3 * hour))
}

pub fn dom_or_dow_test() {
  // Cron runs when either day field matches: the 1st or any Monday.
  let assert Ok(s) = schedule.parse("0 9 1 * 1", sat_noon, sp)
  schedule.next_after(s, sat_noon, sp)
  |> should.equal(Some(sat_noon + 2 * day - 3 * hour))
}

pub fn once_in_future_test() {
  let assert Ok(s) = schedule.parse("2026-11-22 07:15", sat_noon, sp)
  schedule.next_after(s, sat_noon, sp)
  |> should.equal(Some(sat_noon + 19 * hour + 15 * minute))
  schedule.is_once(s) |> should.be_true
}

pub fn once_fires_only_once_test() {
  let assert Ok(s) = schedule.parse("2026-11-22 07:15", sat_noon, sp)
  schedule.next_after(s, sat_noon + day, sp) |> should.equal(None)
}

pub fn once_in_past_is_refused_test() {
  schedule.parse("2026-11-20 07:15", sat_noon, sp)
  |> should.be_error
}

pub fn more_than_hourly_is_refused_test() {
  schedule.parse("* * * * *", sat_noon, sp) |> should.be_error
  schedule.parse("*/15 * * * *", sat_noon, sp) |> should.be_error
  schedule.parse("0,30 * * * *", sat_noon, sp) |> should.be_error
}

pub fn malformed_is_refused_test() {
  schedule.parse("0 25 * * *", sat_noon, sp) |> should.be_error
  schedule.parse("0 5 * *", sat_noon, sp) |> should.be_error
  schedule.parse("amanhã cedo", sat_noon, sp) |> should.be_error
  schedule.parse("0 5 31 2 *", sat_noon, sp) |> should.be_error
}

pub fn describe_test() {
  let assert Ok(s) = schedule.parse("0 5 * * *", sat_noon, sp)
  schedule.spec(s) |> should.equal("0 5 * * *")
  schedule.format_local(sat_noon + 17 * hour, sp)
  |> should.equal("22/11/2026 05:00")
}

pub fn offset_for_timezone_test() {
  schedule.offset_minutes("America/Sao_Paulo") |> should.equal(-180)
  schedule.offset_minutes("UTC") |> should.equal(0)
}

pub fn describe_now_test() {
  schedule.describe_now(sat_noon, sp)
  |> should.equal("sábado, 21/11/2026, 12:00")
  schedule.describe_now(sat_noon + day, sp)
  |> should.equal("domingo, 22/11/2026, 12:00")
}
