//// Tests for the Audit Log Pure module
////
//// Pure tests — no I/O, no actors, no FFI.

import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/audit_log/pure
import supernova/core/audit_log/types.{
  type AuditLogState, AuditDenied, AuditFailure, AuditLogState, AuditSuccess,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helpers
// ============================================================================

fn empty_state() -> AuditLogState {
  AuditLogState(entries: [], max_entries: 1000)
}

fn state_with_entries() -> AuditLogState {
  let entry1 =
    types.success_entry(1000, "agent_1", "tool_call", "read_file", "OK")
  let entry2 =
    types.failure_entry(
      2000,
      "agent_1",
      "tool_call",
      "write_file",
      "Permission denied",
    )
  let entry3 =
    types.denied_entry(
      3000,
      "agent_1",
      "policy:read",
      "/etc/passwd",
      "External read denied",
    )
  let entry4 =
    types.success_entry(4000, "agent_2", "llm_request", "gpt-4", "200 OK")
  let entry5 =
    types.success_entry(
      5000,
      "agent_1",
      "io_read",
      "data.txt",
      "Read 100 bytes",
    )

  AuditLogState(
    entries: [entry5, entry4, entry3, entry2, entry1],
    max_entries: 1000,
  )
}

// ============================================================================
// log Tests — Success Logging
// ============================================================================

pub fn log_success_entry_test() {
  let state = empty_state()
  let entry =
    types.success_entry(1000, "agent_1", "tool_call", "read_file", "OK")

  let #(new_state, commands) = pure.log(state, entry, "workspaces")

  // Entry should be in state
  list.length(new_state.entries)
  |> should.equal(1)

  // Should return a write command
  list.length(commands)
  |> should.equal(1)
}

pub fn log_multiple_entries_test() {
  let state = empty_state()
  let entry1 =
    types.success_entry(1000, "agent_1", "tool_call", "read_file", "OK")
  let entry2 =
    types.success_entry(2000, "agent_1", "tool_call", "write_file", "OK")

  let #(state1, _commands1) = pure.log(state, entry1, "workspaces")
  let #(state2, _commands2) = pure.log(state1, entry2, "workspaces")

  list.length(state2.entries)
  |> should.equal(2)
}

// ============================================================================
// log Tests — Failure Logging
// ============================================================================

pub fn log_failure_entry_test() {
  let state = empty_state()
  let entry =
    types.failure_entry(
      1000,
      "agent_1",
      "tool_call",
      "write_file",
      "Permission denied",
    )

  let #(new_state, commands) = pure.log(state, entry, "workspaces")

  list.length(new_state.entries)
  |> should.equal(1)

  let assert [logged] = new_state.entries
  logged.result
  |> should.equal(AuditFailure)
  logged.details
  |> should.equal("Permission denied")

  list.length(commands)
  |> should.equal(1)
}

// ============================================================================
// log Tests — Denial Logging
// ============================================================================

pub fn log_denied_entry_test() {
  let state = empty_state()
  let entry =
    types.denied_entry(
      1000,
      "agent_1",
      "policy:read",
      "/etc/passwd",
      "External read denied",
    )

  let #(new_state, commands) = pure.log(state, entry, "workspaces")

  list.length(new_state.entries)
  |> should.equal(1)

  let assert [logged] = new_state.entries
  logged.result
  |> should.equal(AuditDenied)
  logged.operation
  |> should.equal("policy:read")
  logged.target
  |> should.equal("/etc/passwd")

  list.length(commands)
  |> should.equal(1)
}

// ============================================================================
// log Tests — Buffer Capacity
// ============================================================================

pub fn log_respects_max_entries_test() {
  let state = AuditLogState(entries: [], max_entries: 3)

  let entry1 = types.success_entry(1000, "agent_1", "op", "target", "d1")
  let entry2 = types.success_entry(2000, "agent_1", "op", "target", "d2")
  let entry3 = types.success_entry(3000, "agent_1", "op", "target", "d3")
  let entry4 = types.success_entry(4000, "agent_1", "op", "target", "d4")

  let #(state1, _) = pure.log(state, entry1, "ws")
  let #(state2, _) = pure.log(state1, entry2, "ws")
  let #(state3, _) = pure.log(state2, entry3, "ws")
  let #(state4, _) = pure.log(state3, entry4, "ws")

  // Should not exceed max_entries
  list.length(state4.entries)
  |> should.equal(3)

  // Newest entry should be first
  let assert [first, ..] = state4.entries
  first.details
  |> should.equal("d4")
}

// ============================================================================
// query Tests — Query by Agent
// ============================================================================

pub fn query_by_agent_test() {
  let state = state_with_entries()

  let filter = types.default_filter()
  let entries = pure.query(state, "agent_1", filter)

  // Should return only agent_1 entries (4 entries: entry1, entry2, entry3, entry5)
  list.length(entries)
  |> should.equal(4)

  // All entries should be for agent_1
  list.each(entries, fn(entry) {
    entry.agent_id
    |> should.equal("agent_1")
  })
}

pub fn query_by_agent_not_found_test() {
  let state = state_with_entries()

  let filter = types.default_filter()
  let entries = pure.query(state, "unknown_agent", filter)

  list.length(entries)
  |> should.equal(0)
}

pub fn query_by_operation_test() {
  let state = state_with_entries()

  let filter = types.operation_filter("tool_call")
  let entries = pure.query(state, "agent_1", filter)

  // Should return only tool_call entries for agent_1
  list.length(entries)
  |> should.equal(2)

  list.each(entries, fn(entry) {
    entry.operation
    |> should.equal("tool_call")
  })
}

pub fn query_by_result_test() {
  let state = state_with_entries()

  let filter = types.result_filter(AuditDenied)
  let entries = pure.query(state, "agent_1", filter)

  // Should return only denied entries for agent_1
  list.length(entries)
  |> should.equal(1)

  let assert [entry] = entries
  entry.result
  |> should.equal(AuditDenied)
}

pub fn query_by_result_failure_test() {
  let state = state_with_entries()

  let filter = types.result_filter(AuditFailure)
  let entries = pure.query(state, "agent_1", filter)

  list.length(entries)
  |> should.equal(1)

  let assert [entry] = entries
  entry.result
  |> should.equal(AuditFailure)
  entry.details
  |> should.equal("Permission denied")
}

// ============================================================================
// recent Tests
// ============================================================================

pub fn recent_returns_limited_entries_test() {
  let state = state_with_entries()

  let entries = pure.recent(state, "agent_1", 2)

  // Should return at most 2 entries
  list.length(entries)
  |> should.equal(2)

  // Should be newest first (entries are prepended)
  let assert [first, second] = entries
  first.timestamp
  |> should.equal(5000)
  second.timestamp
  |> should.equal(3000)
}

pub fn recent_returns_all_if_limit_exceeds_test() {
  let state = state_with_entries()

  let entries = pure.recent(state, "agent_2", 10)

  // agent_2 only has 1 entry
  list.length(entries)
  |> should.equal(1)
}

pub fn recent_empty_for_unknown_agent_test() {
  let state = state_with_entries()

  let entries = pure.recent(state, "unknown", 10)

  list.length(entries)
  |> should.equal(0)
}

// ============================================================================
// get_all Tests
// ============================================================================

pub fn get_all_returns_all_entries_test() {
  let state = state_with_entries()

  let entries = pure.get_all(state)

  list.length(entries)
  |> should.equal(5)
}

// ============================================================================
// get_by_operation Tests
// ============================================================================

pub fn get_by_operation_test() {
  let state = state_with_entries()

  let entries = pure.get_by_operation(state, "tool_call")

  list.length(entries)
  |> should.equal(2)
}

pub fn get_by_operation_not_found_test() {
  let state = state_with_entries()

  let entries = pure.get_by_operation(state, "spawn")

  list.length(entries)
  |> should.equal(0)
}

// ============================================================================
// get_by_result Tests
// ============================================================================

pub fn get_by_result_success_test() {
  let state = state_with_entries()

  let entries = pure.get_by_result(state, AuditSuccess)

  list.length(entries)
  |> should.equal(3)
}

pub fn get_by_result_denied_test() {
  let state = state_with_entries()

  let entries = pure.get_by_result(state, AuditDenied)

  list.length(entries)
  |> should.equal(1)
}

// ============================================================================
// count Tests
// ============================================================================

pub fn count_for_agent_test() {
  let state = state_with_entries()

  pure.count_for_agent(state, "agent_1")
  |> should.equal(4)

  pure.count_for_agent(state, "agent_2")
  |> should.equal(1)

  pure.count_for_agent(state, "unknown")
  |> should.equal(0)
}

pub fn count_by_result_test() {
  let state = state_with_entries()

  pure.count_by_result(state, "agent_1", AuditSuccess)
  |> should.equal(2)

  pure.count_by_result(state, "agent_1", AuditFailure)
  |> should.equal(1)

  pure.count_by_result(state, "agent_1", AuditDenied)
  |> should.equal(1)
}

// ============================================================================
// format_entry Tests
// ============================================================================

pub fn format_entry_test() {
  let entry =
    types.success_entry(1000, "agent_1", "tool_call", "read_file", "OK")

  let formatted = types.format_entry(entry)

  formatted
  |> should.equal("1000 | agent_1 | tool_call | read_file | success | OK")
}

pub fn format_denied_entry_test() {
  let entry =
    types.denied_entry(
      2000,
      "agent_2",
      "policy:write",
      "/etc/passwd",
      "Denied by policy",
    )

  let formatted = types.format_entry(entry)

  formatted
  |> should.equal(
    "2000 | agent_2 | policy:write | /etc/passwd | denied | Denied by policy",
  )
}

// ============================================================================
// Convenience Constructor Tests
// ============================================================================

pub fn success_entry_constructor_test() {
  let entry =
    types.success_entry(1000, "agent_1", "tool_call", "read_file", "OK")

  entry.timestamp
  |> should.equal(1000)
  entry.agent_id
  |> should.equal("agent_1")
  entry.operation
  |> should.equal("tool_call")
  entry.target
  |> should.equal("read_file")
  entry.result
  |> should.equal(AuditSuccess)
  entry.details
  |> should.equal("OK")
}

pub fn failure_entry_constructor_test() {
  let entry =
    types.failure_entry(1000, "agent_1", "tool_call", "write_file", "Error")

  entry.result
  |> should.equal(AuditFailure)
}

pub fn denied_entry_constructor_test() {
  let entry =
    types.denied_entry(1000, "agent_1", "policy:read", "/etc/passwd", "Denied")

  entry.result
  |> should.equal(AuditDenied)
}

// ============================================================================
// result_to_string Tests
// ============================================================================

pub fn result_to_string_test() {
  types.result_to_string(AuditSuccess)
  |> should.equal("success")

  types.result_to_string(AuditFailure)
  |> should.equal("failure")

  types.result_to_string(AuditDenied)
  |> should.equal("denied")
}
