//// When an agenda entry runs: a 5-field cron expression or a single local
//// date and time ("YYYY-MM-DD HH:MM"), both read in a fixed UTC offset.
////
//// The minute field must be a single number, so an entry runs at most once
//// an hour. Everything here is pure: the caller passes the clock and offset.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub opaque type Schedule {
  Once(spec: String, at: Int)
  Cron(
    spec: String,
    minute: Int,
    hours: List(Int),
    days: List(Int),
    months: List(Int),
    weekdays: List(Int),
    days_restricted: Bool,
    weekdays_restricted: Bool,
  )
}

const minute_ms = 60_000

const day_minutes = 1440

/// How many days ahead to look for the next run. Four years covers the 29th
/// of February.
const horizon_days = 1462

/// The UTC offset, in minutes, of a supported timezone. Brazil has had no
/// daylight saving time since 2019, so São Paulo is a fixed UTC−3. Any other
/// zone is an error: guessing would run every entry at the wrong hour.
pub fn timezone_offset(timezone: String) -> Result(Int, Nil) {
  case timezone {
    "America/Sao_Paulo" -> Ok(-180)
    "UTC" | "Etc/UTC" -> Ok(0)
    _ -> Error(Nil)
  }
}

/// Parse an entry's schedule. A single date must lie after `now`; a cron
/// expression must run at least once in the next four years.
pub fn parse(text: String, now: Int, offset: Int) -> Result(Schedule, String) {
  let text = string.trim(text)
  case parse_local(text, offset) {
    Ok(at) ->
      case at > now {
        True -> Ok(Once(spec: text, at: at))
        False -> Error("esse horário já passou")
      }
    Error(_) -> {
      use schedule <- result.try(parse_cron(text))
      case next_after(schedule, now, offset) {
        Some(_) -> Ok(schedule)
        None -> Error("essa expressão nunca acontece")
      }
    }
  }
}

/// The text the schedule was created from.
pub fn spec(schedule: Schedule) -> String {
  schedule.spec
}

pub fn is_once(schedule: Schedule) -> Bool {
  case schedule {
    Once(..) -> True
    Cron(..) -> False
  }
}

/// The first run strictly after `after`, or None when there is none.
pub fn next_after(schedule: Schedule, after: Int, offset: Int) -> Option(Int) {
  case schedule {
    Once(at: at, ..) ->
      case at > after {
        True -> Some(at)
        False -> None
      }
    Cron(..) -> next_cron(schedule, after, offset)
  }
}

/// "YYYY-MM-DD HH:MM" in local time to epoch milliseconds.
pub fn parse_local(text: String, offset: Int) -> Result(Int, Nil) {
  case string.split(string.trim(text), " ") {
    [date, time] ->
      case string.split(date, "-"), string.split(time, ":") {
        [y, mo, d], [h, mi] -> {
          use year <- result.try(int.parse(y))
          use month <- result.try(int.parse(mo))
          use day <- result.try(int.parse(d))
          use hour <- result.try(int.parse(h))
          use minute <- result.try(int.parse(mi))
          case
            valid_date(year, month, day)
            && hour >= 0
            && hour <= 23
            && minute >= 0
            && minute <= 59
          {
            True -> {
              let local =
                days_from_civil(year, month, day)
                * day_minutes
                + hour
                * 60
                + minute
              Ok({ local - offset } * minute_ms)
            }
            False -> Error(Nil)
          }
        }
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Epoch milliseconds as "DD/MM/YYYY HH:MM" in local time.
pub fn format_local(at: Int, offset: Int) -> String {
  let local = floor_div(at, minute_ms) + offset
  let days = floor_div(local, day_minutes)
  let in_day = local - days * day_minutes
  let #(year, month, day) = civil_from_days(days)
  pad2(day)
  <> "/"
  <> pad2(month)
  <> "/"
  <> int.to_string(year)
  <> " "
  <> pad2(in_day / 60)
  <> ":"
  <> pad2(in_day % 60)
}

/// The local weekday, date and time, as the agent reads it in its prompt:
/// "sábado, 21/11/2026, 12:00".
pub fn describe_now(at: Int, offset: Int) -> String {
  let days = floor_div(floor_div(at, minute_ms) + offset, day_minutes)
  let weekday = case { { days % 7 } + 7 + 4 } % 7 {
    0 -> "domingo"
    1 -> "segunda-feira"
    2 -> "terça-feira"
    3 -> "quarta-feira"
    4 -> "quinta-feira"
    5 -> "sexta-feira"
    _ -> "sábado"
  }
  case string.split(format_local(at, offset), " ") {
    [date, time] -> weekday <> ", " <> date <> ", " <> time
    _ -> weekday <> ", " <> format_local(at, offset)
  }
}

// ---------------------------------------------------------------------------
// Cron
// ---------------------------------------------------------------------------

fn parse_cron(text: String) -> Result(Schedule, String) {
  case list.filter(string.split(text, " "), fn(part) { part != "" }) {
    [minute, hour, day, month, weekday] -> {
      use minutes <- result.try(field(minute, 0, 59, "minuto"))
      use minute <- result.try(case minutes {
        [single] -> Ok(single)
        _ ->
          Error(
            "o minuto precisa ser um número só: a agenda roda no máximo uma vez por hora",
          )
      })
      use hours <- result.try(field(hour, 0, 23, "hora"))
      use days <- result.try(field(day, 1, 31, "dia"))
      use months <- result.try(field(month, 1, 12, "mês"))
      use weekdays <- result.try(field(weekday, 0, 7, "dia da semana"))
      let weekdays =
        weekdays
        |> list.map(fn(w) {
          case w {
            7 -> 0
            _ -> w
          }
        })
        |> list.unique
      Ok(Cron(
        spec: text,
        minute: minute,
        hours: hours,
        days: days,
        months: months,
        weekdays: weekdays,
        // As in cron, a field starting with "*" (also "*/n") is a wildcard.
        days_restricted: !string.starts_with(day, "*"),
        weekdays_restricted: !string.starts_with(weekday, "*"),
      ))
    }
    _ ->
      Error(
        "use uma data \"AAAA-MM-DD HH:MM\" ou uma expressão cron de 5 campos",
      )
  }
}

fn field(
  text: String,
  low: Int,
  high: Int,
  name: String,
) -> Result(List(Int), String) {
  let invalid = Error("campo de " <> name <> " inválido: " <> text)
  case list.try_map(string.split(text, ","), field_part(_, low, high)) {
    Ok(parts) ->
      case parts |> list.flatten |> list.unique |> list.sort(int.compare) {
        [] -> invalid
        values -> Ok(values)
      }
    Error(_) -> invalid
  }
}

fn field_part(text: String, low: Int, high: Int) -> Result(List(Int), Nil) {
  let #(range_text, step) = case string.split(text, "/") {
    [range] -> #(range, Ok(1))
    [range, step] -> #(range, int.parse(step))
    _ -> #("", Error(Nil))
  }
  use step <- result.try(step)
  use #(from, to) <- result.try(case string.split(range_text, "-") {
    ["*"] -> Ok(#(low, high))
    [single] -> {
      use value <- result.try(int.parse(single))
      case step {
        1 -> Ok(#(value, value))
        _ -> Ok(#(value, high))
      }
    }
    [a, b] -> {
      use a <- result.try(int.parse(a))
      use b <- result.try(int.parse(b))
      Ok(#(a, b))
    }
    _ -> Error(Nil)
  })
  case step >= 1 && from >= low && to <= high && from <= to {
    True -> Ok(stepped(from, to, step, []))
    False -> Error(Nil)
  }
}

fn stepped(from: Int, to: Int, step: Int, acc: List(Int)) -> List(Int) {
  case from > to {
    True -> list.reverse(acc)
    False -> stepped(from + step, to, step, [from, ..acc])
  }
}

fn next_cron(schedule: Schedule, after: Int, offset: Int) -> Option(Int) {
  let assert Cron(minute: minute, hours: hours, ..) = schedule
  // The first whole local minute strictly after `after`.
  let start = floor_div(after, minute_ms) + offset + 1
  let start_day = floor_div(start, day_minutes)
  let start_in_day = start - start_day * day_minutes
  find_day(schedule, minute, hours, start_day, start_in_day, 0)
  |> option.map(fn(local) { { local - offset } * minute_ms })
}

fn find_day(
  schedule: Schedule,
  minute: Int,
  hours: List(Int),
  day: Int,
  from_in_day: Int,
  searched: Int,
) -> Option(Int) {
  case searched > horizon_days {
    True -> None
    False -> {
      let found = case day_matches(schedule, day) {
        False -> None
        True ->
          hours
          |> list.map(fn(h) { h * 60 + minute })
          |> list.find(fn(m) { m >= from_in_day })
          |> option.from_result
      }
      case found {
        Some(in_day) -> Some(day * day_minutes + in_day)
        None -> find_day(schedule, minute, hours, day + 1, 0, searched + 1)
      }
    }
  }
}

fn day_matches(schedule: Schedule, days_since_epoch: Int) -> Bool {
  let assert Cron(
    days: days,
    months: months,
    weekdays: weekdays,
    days_restricted: days_restricted,
    weekdays_restricted: weekdays_restricted,
    ..,
  ) = schedule
  let #(_, month, day) = civil_from_days(days_since_epoch)
  // 1970-01-01 was a Thursday (4); Sunday is 0.
  let weekday = { { days_since_epoch % 7 } + 7 + 4 } % 7
  let day_ok = list.contains(days, day)
  let weekday_ok = list.contains(weekdays, weekday)
  // Both restricted: either may match. Otherwise the wildcard side matches
  // its own expansion, so both must hold.
  let day_part = case days_restricted && weekdays_restricted {
    True -> day_ok || weekday_ok
    False -> day_ok && weekday_ok
  }
  list.contains(months, month) && day_part
}

// ---------------------------------------------------------------------------
// Calendar (proleptic Gregorian, days since 1970-01-01)
// ---------------------------------------------------------------------------

fn days_from_civil(year: Int, month: Int, day: Int) -> Int {
  let y = case month <= 2 {
    True -> year - 1
    False -> year
  }
  let era = floor_div(y, 400)
  let yoe = y - era * 400
  let mp = { month + 9 } % 12
  let doy = { 153 * mp + 2 } / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146_097 + doe - 719_468
}

fn civil_from_days(days: Int) -> #(Int, Int, Int) {
  let z = days + 719_468
  let era = floor_div(z, 146_097)
  let doe = z - era * 146_097
  let yoe = { doe - doe / 1460 + doe / 36_524 - doe / 146_096 } / 365
  let doy = doe - { 365 * yoe + yoe / 4 - yoe / 100 }
  let mp = { 5 * doy + 2 } / 153
  let day = doy - { 153 * mp + 2 } / 5 + 1
  let month = case mp < 10 {
    True -> mp + 3
    False -> mp - 9
  }
  let year = case month <= 2 {
    True -> yoe + era * 400 + 1
    False -> yoe + era * 400
  }
  #(year, month, day)
}

fn valid_date(year: Int, month: Int, day: Int) -> Bool {
  month >= 1
  && month <= 12
  && day >= 1
  && civil_from_days(days_from_civil(year, month, day)) == #(year, month, day)
}

fn floor_div(a: Int, b: Int) -> Int {
  case int.floor_divide(a, b) {
    Ok(value) -> value
    Error(_) -> 0
  }
}

fn pad2(value: Int) -> String {
  case value < 10 {
    True -> "0" <> int.to_string(value)
    False -> int.to_string(value)
  }
}
