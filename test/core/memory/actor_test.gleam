//// Tests for the Memory Actor module
////
//// Integration tests — uses actors and I/O.

import gleam/list
import gleeunit
import supernova/core/memory/actor

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Lifecycle Tests
// ============================================================================

pub fn start_creates_memory_actor_test() {
  let result = actor.start("/tmp/test_memory.md", "/tmp/test_history.md")
  let assert Ok(memory) = result

  // Verify we can interact with it
  let history = actor.get_history(memory)
  assert history == []

  actor.stop(memory)
}

pub fn stop_gracefully_shuts_down_test() {
  let assert Ok(memory) =
    actor.start("/tmp/test_memory.md", "/tmp/test_history.md")
  actor.stop(memory)
  // Memory actor is now stopped
}

// ============================================================================
// append_history Tests
// ============================================================================

pub fn append_history_creates_entry_test() {
  let assert Ok(memory) =
    actor.start("/tmp/test_memory.md", "/tmp/test_history.md")

  let result = actor.append_history(memory, "session_1", "User said hello")
  let assert Ok(entry) = result

  assert entry.session_id == "session_1"
  assert entry.content == "User said hello"
  assert entry.consolidated == False

  actor.stop(memory)
}

pub fn append_history_adds_to_state_test() {
  let assert Ok(memory) =
    actor.start("/tmp/test_memory.md", "/tmp/test_history.md")

  let _ = actor.append_history(memory, "session_1", "First message")
  let _ = actor.append_history(memory, "session_1", "Second message")

  let history = actor.get_history(memory)
  assert list.length(history) == 2

  actor.stop(memory)
}

pub fn append_history_deduplicates_test() {
  let assert Ok(memory) =
    actor.start("/tmp/test_memory.md", "/tmp/test_history.md")

  let _ = actor.append_history(memory, "session_1", "Same content")
  let _ = actor.append_history(memory, "session_1", "Same content")

  let history = actor.get_history(memory)
  // Should only have one entry due to deduplication
  assert list.length(history) == 1

  actor.stop(memory)
}

// ============================================================================
// consolidate Tests
// ============================================================================

pub fn consolidate_returns_result_test() {
  let assert Ok(memory) =
    actor.start("/tmp/test_memory.md", "/tmp/test_history.md")

  let result = actor.consolidate(memory, 5000)

  // With no entries, should consolidate 0
  assert result.entries_consolidated == 0

  actor.stop(memory)
}

// ============================================================================
// recall Tests
// ============================================================================

pub fn recall_returns_empty_for_no_memories_test() {
  let assert Ok(memory) =
    actor.start("/tmp/test_memory.md", "/tmp/test_history.md")

  let results = actor.recall(memory, "test query")

  assert results == []

  actor.stop(memory)
}

// ============================================================================
// load_context Tests
// ============================================================================

pub fn load_context_returns_empty_for_no_memories_test() {
  let assert Ok(memory) =
    actor.start("/tmp/test_memory.md", "/tmp/test_history.md")

  let context = actor.load_context(memory, 5)

  assert context == ""

  actor.stop(memory)
}

// ============================================================================
// get_history Tests
// ============================================================================

pub fn get_history_returns_empty_initially_test() {
  let assert Ok(memory) =
    actor.start("/tmp/test_memory.md", "/tmp/test_history.md")

  let history = actor.get_history(memory)

  assert history == []

  actor.stop(memory)
}

// ============================================================================
// get_memories Tests
// ============================================================================

pub fn get_memories_returns_empty_initially_test() {
  let assert Ok(memory) =
    actor.start("/tmp/test_memory.md", "/tmp/test_history.md")

  let memories = actor.get_memories(memory)

  assert memories == []

  actor.stop(memory)
}
