//// Memory System — Pure Types
////
//// Pure data structures for the memory system. No FFI, no side effects.
//// These types define the domain model for persistent memory across sessions.

// ============================================================================
// Types
// ============================================================================

/// A single memory entry stored in MEMORY.md.
/// Represents consolidated knowledge from past interactions.
pub type MemoryEntry {
  MemoryEntry(
    /// Unique digest for deduplication (hash of content)
    digest: String,
    /// The memory content
    content: String,
    /// Relevance score (0.0 to 1.0)
    relevance: Float,
    /// Timestamp when the memory was created (milliseconds)
    created_at: Int,
    /// Tags for categorization
    tags: List(String),
  )
}

/// A history entry stored in HISTORY.md.
/// Represents a raw interaction that may later be consolidated into memory.
pub type HistoryEntry {
  HistoryEntry(
    /// Unique digest for deduplication
    digest: String,
    /// The interaction content
    content: String,
    /// Timestamp of the interaction
    timestamp: Int,
    /// Session identifier
    session_id: String,
    /// Whether this entry has been consolidated
    consolidated: Bool,
  )
}

/// Result of a consolidation operation.
/// Consolidation moves old history entries into MEMORY.md.
pub type ConsolidationResult {
  ConsolidationResult(
    /// Number of entries consolidated
    entries_consolidated: Int,
    /// New memory entries created
    new_memories: List(MemoryEntry),
    /// Remaining history entries after consolidation
    remaining_history: List(HistoryEntry),
  )
}

/// Errors that can occur in memory operations.
pub type MemoryError {
  /// Entry not found
  EntryNotFound(digest: String)
  /// Duplicate entry
  DuplicateEntry(digest: String)
  /// Invalid content format
  InvalidContent(reason: String)
  /// File operation failed
  FileOperationError(path: String, reason: String)
}

/// Command pattern for I/O operations.
/// Pure functions return commands; the actor executes them.
pub type MemoryCommand {
  /// Write content to a file
  WriteFile(path: String, content: String)
  /// Read content from a file
  ReadFile(path: String)
  /// Emit a telemetry event
  EmitTelemetry(name: String, measurements: List(#(String, String)))
}

/// The memory state maintained by the actor.
pub type MemoryState {
  MemoryState(
    /// In-memory cache of history entries
    history: List(HistoryEntry),
    /// In-memory cache of memory entries
    memories: List(MemoryEntry),
    /// Path to HISTORY.md file
    history_path: String,
    /// Path to MEMORY.md file
    memory_path: String,
  )
}
