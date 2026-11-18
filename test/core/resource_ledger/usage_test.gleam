//// Tests for the Resource Ledger usage trail and persistence
////
//// Integration tests using temp directories under /tmp. No network, no DB.

import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/resource_ledger/actor
import supernova/core/resource_ledger/types.{LLMUsage, ToolUsage}
import supernova/llm/pricing

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// FFI
// ============================================================================

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "file", "del_dir_r")
fn del_dir_r(path: String) -> Result(Nil, Nil)

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

// ============================================================================
// Helpers
// ============================================================================

/// 2024-06-15T12:00:00Z
const now_ms: Int = 1_718_452_800_000

const day: String = "2024-06-15"

fn temp_dir() -> String {
  "/tmp/supernova_ledger_test_" <> int.to_string(unique_integer())
}

fn cleanup(dir: String) -> Nil {
  let _ = del_dir_r(dir)
  Nil
}

fn assert_close(actual: Float, expected: Float) -> Nil {
  should.be_true(float.absolute_value(actual -. expected) <. 1.0e-12)
}

fn file_exists_now(path: String) -> Bool {
  case file_exists(path) {
    Ok(exists) -> exists
    Error(_) -> False
  }
}

// ============================================================================
// Recording and querying the usage trail
// ============================================================================

pub fn record_usage_per_principal_test() {
  let dir = temp_dir()
  let assert Ok(ledger) =
    actor.start_persistent_with_clock(dir, fn() { now_ms })

  actor.record_llm_usage(ledger, "user_1", "openai", "gpt-4o", 100, 50, 0.01)
  actor.record_tool_usage(ledger, "user_1", "shell", True)
  actor.record_llm_usage(
    ledger,
    "user_2",
    "anthropic",
    "claude",
    200,
    100,
    0.02,
  )

  let user_1_usage = actor.get_usage(ledger, "user_1")
  list.length(user_1_usage)
  |> should.equal(2)

  case user_1_usage {
    [
      LLMUsage("user_1", "openai", "gpt-4o", 100, 50, cost, timestamp, _),
      ToolUsage("user_1", "shell", True, tool_timestamp),
    ] -> {
      assert_close(cost, 0.01)
      timestamp
      |> should.equal(now_ms)
      tool_timestamp
      |> should.equal(now_ms)
    }
    _ -> should.fail()
  }

  list.length(actor.get_usage(ledger, "user_2"))
  |> should.equal(1)

  list.length(actor.get_usage(ledger, "nobody"))
  |> should.equal(0)

  list.length(actor.get_all_usage(ledger))
  |> should.equal(3)

  assert_close(actor.get_daily_cost(ledger, day), 0.03)
  assert_close(actor.get_daily_cost_for(ledger, day, "user_1"), 0.01)
  assert_close(actor.get_daily_cost_for(ledger, day, "user_2"), 0.02)
  assert_close(actor.get_daily_cost(ledger, "2000-01-01"), 0.0)

  actor.stop(ledger)
  process.sleep(100)
  cleanup(dir)
}

pub fn record_usage_on_non_persistent_ledger_test() {
  let assert Ok(ledger) = actor.start()

  actor.record_llm_usage(ledger, "user_1", "openai", "gpt-4o", 10, 5, 0.001)
  actor.record_tool_usage(ledger, "user_1", "calc", False)

  list.length(actor.get_usage(ledger, "user_1"))
  |> should.equal(2)

  // The event day depends on the wall clock, so derive it from the event.
  case actor.get_usage(ledger, "user_1") {
    [LLMUsage(cost_usd: cost_usd, timestamp: timestamp, ..), ToolUsage(..)] -> {
      assert_close(cost_usd, 0.001)

      let event_day = pricing.day_key(timestamp, "UTC")
      assert_close(actor.get_daily_cost_for(ledger, event_day, "user_1"), 0.001)
    }
    _ -> should.fail()
  }

  actor.stop(ledger)
  process.sleep(100)
}

// ============================================================================
// Persistence
// ============================================================================

pub fn persistence_survives_restart_test() {
  let dir = temp_dir()

  let assert Ok(ledger) =
    actor.start_persistent_with_clock(dir, fn() { now_ms })

  actor.record_llm_usage(ledger, "user_1", "openai", "gpt-4o", 100, 50, 0.01)
  actor.record_tool_usage(ledger, "user_1", "shell", True)
  actor.record_llm_usage(ledger, "user_2", "anthropic", "claude", 10, 5, 0.02)

  file_exists_now(dir <> "/" <> day <> ".jsonl")
  |> should.be_true

  actor.stop(ledger)
  process.sleep(100)

  // Restart from the same directory: events are rebuilt from the JSONL file.
  let assert Ok(restarted) =
    actor.start_persistent_with_clock(dir, fn() { now_ms })

  list.length(actor.get_all_usage(restarted))
  |> should.equal(3)

  list.length(actor.get_usage(restarted, "user_1"))
  |> should.equal(2)

  assert_close(actor.get_daily_cost(restarted, day), 0.03)
  assert_close(actor.get_daily_cost_for(restarted, day, "user_1"), 0.01)

  case actor.get_usage(restarted, "user_2") {
    [LLMUsage("user_2", "anthropic", "claude", 10, 5, cost, timestamp, _)] -> {
      assert_close(cost, 0.02)
      timestamp
      |> should.equal(now_ms)
    }
    _ -> should.fail()
  }

  actor.stop(restarted)
  process.sleep(100)
  cleanup(dir)
}

// ============================================================================
// Rotation
// ============================================================================

pub fn rotation_deletes_old_files_and_keeps_recent_test() {
  let dir = temp_dir()
  let assert Ok(_) = ensure_dir(dir)

  // Older than the 30 day window.
  let assert Ok(_) = write_file(dir <> "/2024-05-01.jsonl", "")
  // Exactly 30 days old: kept.
  let assert Ok(_) = write_file(dir <> "/2024-05-16.jsonl", "")
  // Recent.
  let assert Ok(_) = write_file(dir <> "/2024-06-14.jsonl", "")
  // Not a trail file: never rotated.
  let assert Ok(_) = write_file(dir <> "/notes.txt", "keep me")

  let assert Ok(ledger) =
    actor.start_persistent_with_clock(dir, fn() { now_ms })

  file_exists_now(dir <> "/2024-05-01.jsonl")
  |> should.be_false
  file_exists_now(dir <> "/2024-05-16.jsonl")
  |> should.be_true
  file_exists_now(dir <> "/2024-06-14.jsonl")
  |> should.be_true
  file_exists_now(dir <> "/notes.txt")
  |> should.be_true

  // Explicit rotation removes stale files created after start.
  let assert Ok(_) = write_file(dir <> "/2024-01-01.jsonl", "")
  let assert Ok(_) = write_file(dir <> "/2024-06-15.jsonl", "")

  actor.rotate_old_files(ledger, now_ms)

  file_exists_now(dir <> "/2024-01-01.jsonl")
  |> should.be_false
  file_exists_now(dir <> "/2024-06-15.jsonl")
  |> should.be_true

  actor.stop(ledger)
  process.sleep(100)
  cleanup(dir)
}

pub fn rotation_uses_utc_day_key_test() {
  // 2024-06-15T23:30:00Z
  let late_ms = 1_718_494_200_000
  pricing.day_key(late_ms, "UTC")
  |> should.equal("2024-06-15")

  let cutoff_ms = late_ms - { 30 * 86_400_000 }
  pricing.day_key(cutoff_ms, "UTC")
  |> should.equal("2024-05-16")
}

pub fn spend_today_returns_day_and_total_test() {
  let dir = temp_dir()
  let assert Ok(ledger) =
    actor.start_persistent_with_clock_and_day_key(
      dir,
      fn() { now_ms },
      fn(timestamp) { pricing.day_key(timestamp, "UTC") },
    )

  actor.record_llm_usage(ledger, "user_1", "openai", "gpt-4o", 100, 50, 0.25)

  let assert Ok(#(current_day, total)) = actor.try_spend_today(ledger, now_ms)
  current_day |> should.equal(day)
  assert_close(total, 0.25)

  let assert Ok(#(next_day, next_total)) =
    actor.try_spend_today(ledger, now_ms + 86_400_000)
  next_day |> should.equal("2024-06-16")
  assert_close(next_total, 0.0)

  actor.stop(ledger)
  process.sleep(100)
  cleanup(dir)
}

pub fn concurrent_admissions_respect_the_cap_test() {
  let assert Ok(ledger) = actor.start()
  let day = "2024-06-15"

  actor.admit_llm_call(ledger, "call-a", day, 1.0, 0.6)
  |> should.be_ok
  actor.admit_llm_call(ledger, "call-b", day, 1.0, 0.6)
  |> should.be_error

  // Releasing an unrecorded reservation restores the credit.
  actor.admit_llm_call(ledger, "call-c", day, 1.0, 0.4)
  |> should.be_ok
  actor.admit_llm_call(ledger, "call-d", day, 1.0, 0.2)
  |> should.be_error
  actor.release_reservation(ledger, "call-c")
  actor.admit_llm_call(ledger, "call-d", day, 1.0, 0.2)
  |> should.be_ok

  actor.stop(ledger)
  process.sleep(100)
}

pub fn duplicate_call_id_records_once_test() {
  let assert Ok(ledger) = actor.start()

  let _ =
    actor.try_record_llm_usage_with_call_id(
      ledger,
      "user_1",
      "openai",
      "gpt-4o",
      10,
      5,
      0.01,
      "call-once",
    )
  actor.try_record_llm_usage_with_call_id(
    ledger,
    "user_1",
    "openai",
    "gpt-4o",
    10,
    5,
    0.01,
    "call-once",
  )
  |> should.be_ok

  list.length(actor.get_all_usage(ledger)) |> should.equal(1)

  actor.stop(ledger)
  process.sleep(100)
}

pub fn usage_retry_is_idempotent_test() {
  let assert Ok(ledger) = actor.start()

  let assert Ok(Nil) =
    actor.try_record_llm_usage_with_call_id(
      ledger,
      "user_1",
      "openai",
      "gpt-4o",
      100,
      50,
      0.01,
      "call-retry-1",
    )
  let assert Ok(Nil) =
    actor.try_record_llm_usage_with_call_id(
      ledger,
      "user_1",
      "openai",
      "gpt-4o",
      100,
      50,
      0.01,
      "call-retry-1",
    )

  list.length(actor.get_usage(ledger, "user_1")) |> should.equal(1)
  case actor.get_usage(ledger, "user_1") {
    [LLMUsage(timestamp: timestamp, ..)] ->
      assert_close(
        actor.get_daily_cost(ledger, pricing.day_key(timestamp, "UTC")),
        0.01,
      )
    _ -> should.fail()
  }

  actor.stop(ledger)
  process.sleep(100)
}
