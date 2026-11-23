//// Tests for the Audit Log Actor module
////
//// Integration tests — with actors, with I/O.

import gleam/erlang/process
import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/audit_log/actor as audit_actor
import supernova/core/audit_log/types
import test_workspace

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Actor Lifecycle Tests
// ============================================================================

pub fn start_and_stop_test() {
  use root <- test_workspace.with_isolated_workspace("audit-actor")
  let assert Ok(log) = audit_actor.start(root)
  audit_actor.stop(log)

  // Give actor time to terminate
  process.sleep(100)
}

pub fn start_with_capacity_test() {
  use root <- test_workspace.with_isolated_workspace("audit-actor")
  let assert Ok(log) = audit_actor.start_with_capacity(root, 100)
  audit_actor.stop(log)

  process.sleep(100)
}

// ============================================================================
// log_entry Tests
// ============================================================================

pub fn log_success_entry_test() {
  use root <- test_workspace.with_isolated_workspace("audit-actor")
  let assert Ok(log) = audit_actor.start(root)

  let entry =
    types.success_entry(1000, "agent_1", "tool_call", "read_file", "OK")
  audit_actor.log_entry(log, entry)

  let entries = audit_actor.get_all(log)
  list.length(entries)
  |> should.equal(1)

  let assert [logged] = entries
  logged.agent_id
  |> should.equal("agent_1")
  logged.operation
  |> should.equal("tool_call")
  logged.result
  |> should.equal(types.AuditSuccess)

  audit_actor.stop(log)
  process.sleep(100)
}

pub fn log_failure_entry_test() {
  use root <- test_workspace.with_isolated_workspace("audit-actor")
  let assert Ok(log) = audit_actor.start(root)

  let entry =
    types.failure_entry(
      1000,
      "agent_1",
      "tool_call",
      "write_file",
      "Permission denied",
    )
  audit_actor.log_entry(log, entry)

  let entries = audit_actor.get_all(log)
  list.length(entries)
  |> should.equal(1)

  let assert [logged] = entries
  logged.result
  |> should.equal(types.AuditFailure)

  audit_actor.stop(log)
  process.sleep(100)
}

pub fn log_denied_entry_test() {
  use root <- test_workspace.with_isolated_workspace("audit-actor")
  let assert Ok(log) = audit_actor.start(root)

  let entry =
    types.denied_entry(
      1000,
      "agent_1",
      "policy:read",
      "/etc/passwd",
      "External read denied",
    )
  audit_actor.log_entry(log, entry)

  let entries = audit_actor.get_all(log)
  list.length(entries)
  |> should.equal(1)

  let assert [logged] = entries
  logged.result
  |> should.equal(types.AuditDenied)
  logged.operation
  |> should.equal("policy:read")

  audit_actor.stop(log)
  process.sleep(100)
}

pub fn log_multiple_entries_test() {
  use root <- test_workspace.with_isolated_workspace("audit-actor")
  let assert Ok(log) = audit_actor.start(root)

  let entry1 =
    types.success_entry(1000, "agent_1", "tool_call", "read_file", "OK")
  let entry2 =
    types.success_entry(2000, "agent_1", "llm_request", "gpt-4", "OK")
  let entry3 =
    types.denied_entry(3000, "agent_2", "policy:write", "/etc/passwd", "Denied")

  audit_actor.log_entry(log, entry1)
  audit_actor.log_entry(log, entry2)
  audit_actor.log_entry(log, entry3)

  let entries = audit_actor.get_all(log)
  list.length(entries)
  |> should.equal(3)

  audit_actor.stop(log)
  process.sleep(100)
}

// ============================================================================
// query Tests
// ============================================================================

pub fn query_by_agent_test() {
  use root <- test_workspace.with_isolated_workspace("audit-actor")
  let assert Ok(log) = audit_actor.start(root)

  let entry1 =
    types.success_entry(1000, "agent_1", "tool_call", "read_file", "OK")
  let entry2 =
    types.success_entry(2000, "agent_2", "tool_call", "write_file", "OK")
  let entry3 =
    types.success_entry(3000, "agent_1", "llm_request", "gpt-4", "OK")

  audit_actor.log_entry(log, entry1)
  audit_actor.log_entry(log, entry2)
  audit_actor.log_entry(log, entry3)

  let filter = types.default_filter()
  let entries = audit_actor.query(log, "agent_1", filter)

  list.length(entries)
  |> should.equal(2)

  audit_actor.stop(log)
  process.sleep(100)
}

pub fn query_by_operation_test() {
  use root <- test_workspace.with_isolated_workspace("audit-actor")
  let assert Ok(log) = audit_actor.start(root)

  let entry1 =
    types.success_entry(1000, "agent_1", "tool_call", "read_file", "OK")
  let entry2 =
    types.success_entry(2000, "agent_1", "llm_request", "gpt-4", "OK")
  let entry3 =
    types.success_entry(3000, "agent_1", "tool_call", "write_file", "OK")

  audit_actor.log_entry(log, entry1)
  audit_actor.log_entry(log, entry2)
  audit_actor.log_entry(log, entry3)

  let filter = types.operation_filter("tool_call")
  let entries = audit_actor.query(log, "agent_1", filter)

  list.length(entries)
  |> should.equal(2)

  audit_actor.stop(log)
  process.sleep(100)
}

pub fn query_by_result_test() {
  use root <- test_workspace.with_isolated_workspace("audit-actor")
  let assert Ok(log) = audit_actor.start(root)

  let entry1 =
    types.success_entry(1000, "agent_1", "tool_call", "read_file", "OK")
  let entry2 =
    types.failure_entry(2000, "agent_1", "tool_call", "write_file", "Error")
  let entry3 =
    types.denied_entry(3000, "agent_1", "policy:read", "/etc/passwd", "Denied")

  audit_actor.log_entry(log, entry1)
  audit_actor.log_entry(log, entry2)
  audit_actor.log_entry(log, entry3)

  let filter = types.result_filter(types.AuditDenied)
  let entries = audit_actor.query(log, "agent_1", filter)

  list.length(entries)
  |> should.equal(1)

  let assert [entry] = entries
  entry.result
  |> should.equal(types.AuditDenied)

  audit_actor.stop(log)
  process.sleep(100)
}

// ============================================================================
// recent Tests
// ============================================================================

pub fn recent_returns_limited_entries_test() {
  use root <- test_workspace.with_isolated_workspace("audit-actor")
  let assert Ok(log) = audit_actor.start(root)

  let entry1 =
    types.success_entry(1000, "agent_1", "tool_call", "read_file", "OK")
  let entry2 =
    types.success_entry(2000, "agent_1", "llm_request", "gpt-4", "OK")
  let entry3 = types.success_entry(3000, "agent_1", "io_read", "data.txt", "OK")

  audit_actor.log_entry(log, entry1)
  audit_actor.log_entry(log, entry2)
  audit_actor.log_entry(log, entry3)

  let entries = audit_actor.recent(log, "agent_1", 2)

  list.length(entries)
  |> should.equal(2)

  // Newest first
  let assert [first, ..] = entries
  first.timestamp
  |> should.equal(3000)

  audit_actor.stop(log)
  process.sleep(100)
}

// ============================================================================
// count_for_agent Tests
// ============================================================================

pub fn count_for_agent_test() {
  use root <- test_workspace.with_isolated_workspace("audit-actor")
  let assert Ok(log) = audit_actor.start(root)

  let entry1 =
    types.success_entry(1000, "agent_1", "tool_call", "read_file", "OK")
  let entry2 =
    types.success_entry(2000, "agent_2", "tool_call", "write_file", "OK")
  let entry3 =
    types.success_entry(3000, "agent_1", "llm_request", "gpt-4", "OK")

  audit_actor.log_entry(log, entry1)
  audit_actor.log_entry(log, entry2)
  audit_actor.log_entry(log, entry3)

  audit_actor.count_for_agent(log, "agent_1")
  |> should.equal(2)

  audit_actor.count_for_agent(log, "agent_2")
  |> should.equal(1)

  audit_actor.count_for_agent(log, "unknown")
  |> should.equal(0)

  audit_actor.stop(log)
  process.sleep(100)
}

// ============================================================================
// get_by_operation Tests
// ============================================================================

pub fn get_by_operation_test() {
  use root <- test_workspace.with_isolated_workspace("audit-actor")
  let assert Ok(log) = audit_actor.start(root)

  let entry1 =
    types.success_entry(1000, "agent_1", "tool_call", "read_file", "OK")
  let entry2 =
    types.success_entry(2000, "agent_2", "llm_request", "gpt-4", "OK")
  let entry3 =
    types.success_entry(3000, "agent_1", "tool_call", "write_file", "OK")

  audit_actor.log_entry(log, entry1)
  audit_actor.log_entry(log, entry2)
  audit_actor.log_entry(log, entry3)

  let entries = audit_actor.get_by_operation(log, "tool_call")

  list.length(entries)
  |> should.equal(2)

  audit_actor.stop(log)
  process.sleep(100)
}

// ============================================================================
// Disk
// ============================================================================

/// The entry reaches the disk even when neither the log root nor the agent's
/// directory exists yet (as on a fresh data_dir): the directories are made.
pub fn entries_reach_the_disk_on_a_fresh_root_test() {
  use root <- test_workspace.with_isolated_workspace("audit-disk")
  let log_root = root <> "/audit_log"
  let assert Ok(log) = audit_actor.start(log_root)
  audit_actor.log_entry(
    log,
    types.AuditEntry(
      timestamp: 1000,
      agent_id: "sim:ana",
      operation: "tool_call",
      target: "buscar_conversa",
      result: types.AuditSuccess,
      details: "ok",
    ),
  )
  // A call after the cast: the actor handled the entry before answering.
  let _ = audit_actor.recent(log, "sim:ana", 1)
  audit_actor.stop(log)
  let assert Ok(raw) = read_file(log_root <> "/sim:ana/.supernova/audit.log")
  raw
  |> should.equal(
    "1000 | sim:ana | tool_call | buscar_conversa | success | ok\n",
  )
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)
