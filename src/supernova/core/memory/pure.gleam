//// Memory System — Pure Functions
////
//// Pure functions for memory operations. No FFI, no side effects.
//// Functions take state and return new state + commands for the actor to execute.
////
//// ## Usage
////
//// ```gleam
//// let #(new_state, commands) = pure.append_entry(state, entry)
//// ```

import gleam/float
import gleam/list
import gleam/string
import supernova/core/memory/types.{
  type ConsolidationResult, type HistoryEntry, type MemoryCommand,
  type MemoryEntry, type MemoryState, ConsolidationResult, EmitTelemetry,
  HistoryEntry, MemoryEntry, MemoryState, WriteFile,
}

// ============================================================================
// Public API
// ============================================================================

/// Append a new history entry to the state.
///
/// Returns the updated state and commands to persist the change.
/// Deduplicates by digest — if an entry with the same digest exists, it's skipped.
pub fn append_entry(
  state: MemoryState,
  entry: HistoryEntry,
) -> #(MemoryState, List(MemoryCommand)) {
  case has_digest(state.history, entry.digest) {
    True -> {
      // Duplicate — skip and emit telemetry
      let commands = [
        EmitTelemetry("memory:duplicate_skipped", [
          #("digest", entry.digest),
        ]),
      ]
      #(state, commands)
    }
    False -> {
      let new_history = [entry, ..state.history]
      let new_state = MemoryState(..state, history: new_history)
      let history_content = render_history(new_history)
      let commands = [
        WriteFile(state.history_path, history_content),
        EmitTelemetry("memory:entry_appended", [
          #("digest", entry.digest),
          #("session_id", entry.session_id),
        ]),
      ]
      #(new_state, commands)
    }
  }
}

/// Consolidate old history entries into memory.
///
/// Moves entries older than `max_age_ms` from HISTORY.md to MEMORY.md.
/// Returns the consolidation result with new memories and remaining history.
pub fn consolidate(
  state: MemoryState,
  current_time: Int,
  max_age_ms: Int,
) -> #(MemoryState, ConsolidationResult, List(MemoryCommand)) {
  let cutoff = current_time - max_age_ms

  let #(to_consolidate, remaining) =
    list.partition(state.history, fn(entry) {
      entry.timestamp < cutoff && !entry.consolidated
    })

  let new_memories =
    to_consolidate
    |> list.map(history_to_memory)

  let all_memories = list.append(state.memories, new_memories)
  let consolidated_remaining =
    list.map(remaining, fn(e) { HistoryEntry(..e, consolidated: True) })

  let new_state =
    MemoryState(
      ..state,
      history: consolidated_remaining,
      memories: all_memories,
    )

  let result =
    ConsolidationResult(
      entries_consolidated: list.length(to_consolidate),
      new_memories: new_memories,
      remaining_history: consolidated_remaining,
    )

  let commands = [
    WriteFile(state.history_path, render_history(consolidated_remaining)),
    WriteFile(state.memory_path, render_memories(all_memories)),
    EmitTelemetry("memory:consolidated", [
      #("entries", string.inspect(list.length(to_consolidate))),
    ]),
  ]

  #(new_state, result, commands)
}

/// Filter memory entries by relevance score.
///
/// Returns entries with relevance >= min_relevance, sorted by relevance descending.
pub fn filter_by_relevance(
  memories: List(MemoryEntry),
  min_relevance: Float,
) -> List(MemoryEntry) {
  memories
  |> list.filter(fn(m) { m.relevance >=. min_relevance })
  |> list.sort(fn(a, b) { float.compare(b.relevance, a.relevance) })
}

/// Build context string from relevant memories for prompt injection.
///
/// Selects top memories by relevance and formats them as context.
pub fn build_context(memories: List(MemoryEntry), max_entries: Int) -> String {
  let top_memories =
    memories
    |> list.sort(fn(a, b) { float.compare(b.relevance, a.relevance) })
    |> list.take(max_entries)

  case list.is_empty(top_memories) {
    True -> ""
    False -> {
      let header = "## Relevant Context from Memory\n\n"
      let entries =
        top_memories
        |> list.map(fn(m) { "- " <> m.content })
        |> string.join("\n")
      header <> entries <> "\n"
    }
  }
}

/// Recall memories matching a query (simple keyword matching).
///
/// Searches memory content for the query string (case-insensitive).
/// Returns matching entries sorted by relevance.
pub fn recall(memories: List(MemoryEntry), query: String) -> List(MemoryEntry) {
  let query_lower = string.lowercase(query)
  memories
  |> list.filter(fn(m) {
    string.contains(string.lowercase(m.content), query_lower)
  })
  |> list.sort(fn(a, b) { float.compare(b.relevance, a.relevance) })
}

/// Generate a digest (hash) for content deduplication.
///
/// Simple hash based on content length and first/last chars.
/// In production, use a proper hash function via FFI in the actor.
pub fn generate_digest(content: String) -> String {
  let len = string.length(content)
  let first = string.slice(content, 0, 8)
  let last = string.slice(content, len - 8, 8)
  string.inspect(len) <> ":" <> first <> ":" <> last
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Check if a list of history entries already contains a digest.
fn has_digest(entries: List(HistoryEntry), digest: String) -> Bool {
  list.any(entries, fn(e) { e.digest == digest })
}

/// Convert a history entry to a memory entry.
fn history_to_memory(entry: HistoryEntry) -> MemoryEntry {
  MemoryEntry(
    digest: entry.digest,
    content: entry.content,
    relevance: 0.5,
    created_at: entry.timestamp,
    tags: [],
  )
}

/// Render history entries as markdown content.
fn render_history(entries: List(HistoryEntry)) -> String {
  case list.is_empty(entries) {
    True -> "# History\n\n_No entries yet._\n"
    False -> {
      let header = "# History\n\n"
      let items =
        entries
        |> list.map(render_history_entry)
        |> string.join("\n---\n\n")
      header <> items <> "\n"
    }
  }
}

/// Render a single history entry as markdown.
fn render_history_entry(entry: HistoryEntry) -> String {
  let status = case entry.consolidated {
    True -> "✓ consolidated"
    False -> "○ pending"
  }
  "## ["
  <> entry.session_id
  <> "] "
  <> string.inspect(entry.timestamp)
  <> "\n\n"
  <> "**Status:** "
  <> status
  <> "\n\n"
  <> "**Digest:** `"
  <> entry.digest
  <> "`\n\n"
  <> entry.content
}

/// Render memory entries as markdown content.
fn render_memories(entries: List(MemoryEntry)) -> String {
  case list.is_empty(entries) {
    True -> "# Memory\n\n_No memories yet._\n"
    False -> {
      let header = "# Memory\n\n"
      let items =
        entries
        |> list.map(render_memory_entry)
        |> string.join("\n---\n\n")
      header <> items <> "\n"
    }
  }
}

/// Render a single memory entry as markdown.
fn render_memory_entry(entry: MemoryEntry) -> String {
  let tags_str = case list.is_empty(entry.tags) {
    True -> ""
    False ->
      "\n\n**Tags:** "
      <> string.join(list.map(entry.tags, fn(t) { "`" <> t <> "`" }), ", ")
  }
  "## "
  <> entry.digest
  <> "\n\n"
  <> "**Relevance:** "
  <> string.inspect(entry.relevance)
  <> "\n\n"
  <> entry.content
  <> tags_str
}
