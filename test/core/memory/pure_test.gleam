//// Tests for the Memory Pure module
////
//// Pure tests — no I/O, no actors, no FFI.

import gleam/list
import gleeunit
import supernova/core/memory/pure
import supernova/core/memory/types.{
  type HistoryEntry, type MemoryState, HistoryEntry, MemoryEntry, MemoryState,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helper: Create empty state
// ============================================================================

fn empty_state() -> MemoryState {
  MemoryState(
    history: [],
    memories: [],
    history_path: "HISTORY.md",
    memory_path: "MEMORY.md",
  )
}

fn sample_entry() -> HistoryEntry {
  HistoryEntry(
    digest: "test-digest-1",
    content: "User asked about weather",
    timestamp: 1000,
    session_id: "session_1",
    consolidated: False,
  )
}

// ============================================================================
// append_entry Tests
// ============================================================================

pub fn append_entry_adds_to_history_test() {
  let state = empty_state()
  let entry = sample_entry()

  let #(new_state, _commands) = pure.append_entry(state, entry)

  assert new_state.history == [entry]
}

pub fn append_entry_returns_commands_test() {
  let state = empty_state()
  let entry = sample_entry()

  let #(_new_state, commands) = pure.append_entry(state, entry)

  // Should have WriteFile and EmitTelemetry commands
  assert list.length(commands) == 2
}

pub fn append_entry_deduplicates_by_digest_test() {
  let state = empty_state()
  let entry = sample_entry()

  let #(state1, _commands1) = pure.append_entry(state, entry)
  let #(state2, commands2) = pure.append_entry(state1, entry)

  // Second append should be skipped (duplicate)
  assert state2.history == [entry]
  assert list.length(commands2) == 1
}

pub fn append_entry_multiple_entries_test() {
  let state = empty_state()
  let entry1 = sample_entry()
  let entry2 =
    HistoryEntry(
      digest: "test-digest-2",
      content: "User asked about time",
      timestamp: 2000,
      session_id: "session_1",
      consolidated: False,
    )

  let #(state1, _) = pure.append_entry(state, entry1)
  let #(state2, _) = pure.append_entry(state1, entry2)

  assert state2.history == [entry2, entry1]
}

// ============================================================================
// consolidate Tests
// ============================================================================

pub fn consolidate_moves_old_entries_test() {
  let state = empty_state()
  let old_entry =
    HistoryEntry(
      digest: "old-1",
      content: "Old interaction",
      timestamp: 100,
      session_id: "session_1",
      consolidated: False,
    )
  let new_entry =
    HistoryEntry(
      digest: "new-1",
      content: "New interaction",
      timestamp: 9000,
      session_id: "session_1",
      consolidated: False,
    )

  let #(state1, _) = pure.append_entry(state, old_entry)
  let #(state2, _) = pure.append_entry(state1, new_entry)

  let #(_state3, result, _commands) = pure.consolidate(state2, 10_000, 5000)

  // Only old_entry should be consolidated (timestamp 100 < 10000 - 5000 = 5000)
  assert result.entries_consolidated == 1
  assert list.length(result.remaining_history) == 1
}

pub fn consolidate_no_entries_when_all_recent_test() {
  let state = empty_state()
  let entry =
    HistoryEntry(
      digest: "recent-1",
      content: "Recent interaction",
      timestamp: 9000,
      session_id: "session_1",
      consolidated: False,
    )

  let #(state1, _) = pure.append_entry(state, entry)
  let #(_state2, result, _commands) = pure.consolidate(state1, 10_000, 5000)

  // Entry is recent (9000 >= 10000 - 5000 = 5000), should not be consolidated
  assert result.entries_consolidated == 0
  assert list.length(result.remaining_history) == 1
}

pub fn consolidate_creates_memory_entries_test() {
  let state = empty_state()
  let entry =
    HistoryEntry(
      digest: "old-1",
      content: "Old interaction",
      timestamp: 100,
      session_id: "session_1",
      consolidated: False,
    )

  let #(state1, _) = pure.append_entry(state, entry)
  let #(state2, result, _commands) = pure.consolidate(state1, 10_000, 5000)

  assert result.entries_consolidated == 1
  assert state2.memories == result.new_memories
}

pub fn consolidate_returns_commands_test() {
  let state = empty_state()
  let entry =
    HistoryEntry(
      digest: "old-1",
      content: "Old interaction",
      timestamp: 100,
      session_id: "session_1",
      consolidated: False,
    )

  let #(state1, _) = pure.append_entry(state, entry)
  let #(_state2, _result, commands) = pure.consolidate(state1, 10_000, 5000)

  // Should have WriteFile (history), WriteFile (memory), EmitTelemetry
  assert list.length(commands) == 3
}

// ============================================================================
// filter_by_relevance Tests
// ============================================================================

pub fn filter_by_relevance_filters_low_scores_test() {
  let memories = [
    MemoryEntry(
      digest: "m1",
      content: "High relevance",
      relevance: 0.9,
      created_at: 0,
      tags: [],
    ),
    MemoryEntry(
      digest: "m2",
      content: "Low relevance",
      relevance: 0.2,
      created_at: 0,
      tags: [],
    ),
    MemoryEntry(
      digest: "m3",
      content: "Medium relevance",
      relevance: 0.6,
      created_at: 0,
      tags: [],
    ),
  ]

  let filtered = pure.filter_by_relevance(memories, 0.5)

  assert list.length(filtered) == 2
  let assert Ok(first) = list.first(filtered)
  assert first.digest == "m1"
}

pub fn filter_by_relevance_empty_list_test() {
  let filtered = pure.filter_by_relevance([], 0.5)
  assert filtered == []
}

pub fn filter_by_relevance_sorts_by_relevance_test() {
  let memories = [
    MemoryEntry(
      digest: "m1",
      content: "Low",
      relevance: 0.3,
      created_at: 0,
      tags: [],
    ),
    MemoryEntry(
      digest: "m2",
      content: "High",
      relevance: 0.9,
      created_at: 0,
      tags: [],
    ),
    MemoryEntry(
      digest: "m3",
      content: "Medium",
      relevance: 0.6,
      created_at: 0,
      tags: [],
    ),
  ]

  let filtered = pure.filter_by_relevance(memories, 0.0)

  assert list.length(filtered) == 3
  let assert Ok(first) = list.first(filtered)
  assert first.digest == "m2"
  // Verify order by checking the list structure
  let digests = list.map(filtered, fn(m) { m.digest })
  assert digests == ["m2", "m3", "m1"]
}

// ============================================================================
// build_context Tests
// ============================================================================

pub fn build_context_returns_formatted_string_test() {
  let memories = [
    MemoryEntry(
      digest: "m1",
      content: "User prefers concise answers",
      relevance: 0.9,
      created_at: 0,
      tags: [],
    ),
    MemoryEntry(
      digest: "m2",
      content: "User works in UTC-3 timezone",
      relevance: 0.7,
      created_at: 0,
      tags: [],
    ),
  ]

  let context = pure.build_context(memories, 5)

  assert context
    == "## Relevant Context from Memory\n\n- User prefers concise answers\n- User works in UTC-3 timezone\n"
}

pub fn build_context_limits_entries_test() {
  let memories = [
    MemoryEntry(
      digest: "m1",
      content: "First",
      relevance: 0.9,
      created_at: 0,
      tags: [],
    ),
    MemoryEntry(
      digest: "m2",
      content: "Second",
      relevance: 0.8,
      created_at: 0,
      tags: [],
    ),
    MemoryEntry(
      digest: "m3",
      content: "Third",
      relevance: 0.7,
      created_at: 0,
      tags: [],
    ),
  ]

  let context = pure.build_context(memories, 2)

  assert context == "## Relevant Context from Memory\n\n- First\n- Second\n"
}

pub fn build_context_empty_memories_test() {
  let context = pure.build_context([], 5)
  assert context == ""
}

// ============================================================================
// recall Tests
// ============================================================================

pub fn recall_finds_matching_memories_test() {
  let memories = [
    MemoryEntry(
      digest: "m1",
      content: "User prefers concise answers",
      relevance: 0.9,
      created_at: 0,
      tags: [],
    ),
    MemoryEntry(
      digest: "m2",
      content: "User works in UTC-3 timezone",
      relevance: 0.7,
      created_at: 0,
      tags: [],
    ),
  ]

  let results = pure.recall(memories, "concise")

  assert list.length(results) == 1
  let assert Ok(first) = list.first(results)
  assert first.digest == "m1"
}

pub fn recall_case_insensitive_test() {
  let memories = [
    MemoryEntry(
      digest: "m1",
      content: "User prefers CONCISE answers",
      relevance: 0.9,
      created_at: 0,
      tags: [],
    ),
  ]

  let results = pure.recall(memories, "concise")

  assert list.length(results) == 1
}

pub fn recall_no_matches_test() {
  let memories = [
    MemoryEntry(
      digest: "m1",
      content: "User prefers concise answers",
      relevance: 0.9,
      created_at: 0,
      tags: [],
    ),
  ]

  let results = pure.recall(memories, "weather")

  assert results == []
}

// ============================================================================
// generate_digest Tests
// ============================================================================

pub fn generate_digest_creates_consistent_hash_test() {
  let digest1 = pure.generate_digest("Hello, world!")
  let digest2 = pure.generate_digest("Hello, world!")

  assert digest1 == digest2
}

pub fn generate_digest_different_content_test() {
  let digest1 = pure.generate_digest("Hello")
  let digest2 = pure.generate_digest("World")

  assert digest1 != digest2
}
